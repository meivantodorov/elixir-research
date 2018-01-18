defmodule Aecore.Peers.Worker do
  @moduledoc """
  Peer manager module
  """

  use GenServer

  alias Aecore.Peers.Sync
  alias Aehttpclient.Client
  alias Aecore.Chain.Worker, as: Chain
  alias Aecore.Structures.Block
  alias Aecore.Structures.SignedTx
  alias Aecore.Chain.BlockValidation

  require Logger

  @mersenne_prime 2_147_483_647
  @peers_max_count Application.get_env(:aecore, :peers)[:peers_max_count]
  @probability_of_peer_remove_when_max 0.5


  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{peers: %{},
                                       nonce: get_peer_nonce(),
                                       pending_channel_invites: %{},
                                       open_channels: %{}},
                         name: __MODULE__)
  end

  ## Client side

  @spec is_chain_synced?() :: boolean()
  def is_chain_synced?() do
    GenServer.call(__MODULE__, :is_chain_synced)
  end

  @spec add_peer(term) :: :ok | {:error, term()} | :error
  def add_peer(uri) do
    GenServer.call(__MODULE__, {:add_peer, uri})
  end

  def add_channel_invite(peer_pubkey, peer_uri, peer_lock_amount, fee) do
    GenServer.call(__MODULE__, {:add_channel_invite, peer_pubkey, peer_uri, peer_lock_amount, fee})
  end

  def remove_channel_invite(peer_uri) do
    GenServer.call(__MODULE__, {:remove_channel_invite, peer_uri})
  end

  def pending_channel_invites() do
    GenServer.call(__MODULE__, :pending_channel_invites)
  end

  def open_channel(address, tx, uri) do
    GenServer.call(__MODULE__, {:open_channel, address, tx, uri})
  end

  def close_channel(address) do
    GenServer.call(__MODULE__, {:close_channel, address})
  end

  def add_channel_tx(address, tx) do
    GenServer.call(__MODULE__, {:add_channel_tx, address, tx})
  end

  def add_pending_tx(address,tx) do
    GenServer.call(__MODULE__, {:add_pending_tx, address, tx})
  end

  def pending_tx(address) do
    GenServer.call(__MODULE__, {:pending_tx, address})
  end

  def accept_pending_tx(address) do
    GenServer.call(__MODULE__, {:accept_pending_tx, address})
  end

  def open_channels() do
    GenServer.call(__MODULE__, :open_channels)
  end

  @spec remove_peer(term) :: :ok | :error
  def remove_peer(uri) do
    GenServer.call(__MODULE__, {:remove_peer, uri})
  end

  @spec check_peers() :: :ok
  def check_peers() do
    GenServer.call(__MODULE__, :check_peers)
  end

  @spec all_uris() :: list(binary())
  def all_uris() do
    all_peers()
    |> Map.values()
    |> Enum.map(fn(%{uri: uri}) -> uri end)
  end

  @spec all_peers() :: map()
  def all_peers() do
    GenServer.call(__MODULE__, :all_peers)
  end

  @spec genesis_block_header_hash() :: term()
  def genesis_block_header_hash() do
    Block.genesis_block().header
    |> BlockValidation.block_header_hash()
    |> Base.encode16()
  end

  @spec schedule_add_peer(uri :: term(), nonce :: integer()) :: term()
  def schedule_add_peer(uri, nonce) do
    GenServer.cast(__MODULE__, {:schedule_add_peer, uri, nonce})
  end

  @doc """
  Gets a random peer nonce
  """
  @spec get_peer_nonce() :: integer()
  def get_peer_nonce() do
    case :ets.info(:nonce_table) do
      :undefined -> create_nonce_table()
      _ -> :table_created
    end
    case :ets.lookup(:nonce_table, :nonce) do
      [] ->
        nonce = :rand.uniform(@mersenne_prime)
        :ets.insert(:nonce_table, {:nonce, nonce})
        nonce
      _ ->
        :ets.lookup(:nonce_table, :nonce)[:nonce]
    end
  end

  @spec broadcast_block(%Block{}) :: :ok
  def broadcast_block(block) do
    spawn fn ->
      Client.send_block(block, all_uris())
    end
    :ok
  end

  @spec broadcast_tx(%SignedTx{}) :: :ok
  def broadcast_tx(tx) do
    spawn fn ->
      Client.send_tx(tx, all_uris())
    end
    :ok
  end

  ## Server side

  def init(initial_peers) do
    {:ok, initial_peers}
  end

  def handle_call(:is_chain_synced, _from, %{peers: peers} = state) do
    local_latest_block_height = Chain.top_height()
    peer_uris = peers
      |> Map.values()
      |> Enum.map(fn(%{uri: uri}) -> uri end)
    peer_latest_block_heights =
      Enum.map(peer_uris, fn(uri) ->
          case Client.get_info(uri) do
            {:ok, info} ->
              info.current_block_height
            :error ->
              0
          end
        end)
    is_synced =
      if(Enum.empty?(peer_uris)) do
        true
      else
        Enum.max(peer_latest_block_heights) <= local_latest_block_height
      end

    {:reply, is_synced, state}
  end

  def handle_call({:add_peer,uri}, _from, state) do
    add_peer(uri, state)
  end

  def handle_call({:add_channel_invite, peer_pubkey, uri, lock_amount, fee}, _from,
                  %{pending_channel_invites: invites} = state) do
    updated_invites = Map.put(invites, peer_pubkey, %{lock_amount: lock_amount,
                                              fee: fee,
                                              uri: uri})

    {:reply, :ok, %{state | pending_channel_invites: updated_invites}}
  end

  def handle_call({:remove_channel_invite, peer_address}, _from,
                  %{pending_channel_invites: invites} = state) do
    updated_invites = Map.delete(invites, peer_address)

    {:reply, :ok, %{state | pending_channel_invites: updated_invites}}
  end

  def handle_call(:pending_channel_invites, _from,
                  %{pending_channel_invites: invites} = state) do
    {:reply, invites, state}
  end

  def handle_call({:open_channel, address, tx, uri}, _from,
                  %{open_channels: channels} = state) do
    updated_channels =
      Map.put(channels, address, %{uri: uri, txs: [tx], pending_tx: nil})

    {:reply, :ok, %{state | open_channels: updated_channels}}
  end

  def handle_call({:close_channel, address}, _from,
                  %{open_channels: channels} = state) do
    updated_channels = Map.delete(channels, address)

    {:reply, :ok, %{state | open_channels: updated_channels}}
  end

  def handle_call({:add_channel_tx, address, tx}, _from,
                  %{open_channels: channels} = state) do
    updated_txs = [tx | channels[address].txs]
    updated_channels =
      %{channels | address => %{channels[address] | txs: updated_txs}}

    {:reply, :ok, %{state | open_channels: updated_channels}}
  end

  def handle_call({:add_pending_tx, address, tx}, _from,
                  %{open_channels: channels} = state) do
    updated_channels =
      %{channels | address =>
                   %{channels[address] | pending_tx: tx}}

    {:reply, :ok, %{state | open_channels: updated_channels}}
  end

  def handle_call({:pending_tx, address}, _from,
                  %{open_channels: channels} = state) do
    {:reply, channels[address].pending_tx, state}
  end

  def handle_call({:accept_pending_tx, address}, _from,
                  %{open_channels: channels} = state) do
    updated_channels = %{channels[address] | pending_tx: nil}

    {:reply, :ok, %{state | open_channels: updated_channels}}
  end

  def handle_call(:open_channels, _from, %{open_channels: channels} = state) do
    {:reply, channels, state}
  end

  def handle_call({:remove_peer, uri}, _from, %{peers: peers} = state) do
    if Map.has_key?(peers, uri) do
      Logger.info(fn -> "Removed #{uri} from the peer list" end)
      {:reply, :ok, %{state | peers: Map.delete(peers, uri)}}
    else
      Logger.error(fn -> "#{uri} is not in the peer list" end)
      {:reply, {:error, "Peer not found"}, %{state | peers: peers}}
    end
  end

  @doc """
  Filters the peers map by checking if the response status from a GET /info
  request is :ok and if the genesis block hash is the same as the one
  in the current node. After that the current block hash for every peer
  is updated if the one in the latest GET /info request is different.
  """
  def handle_call(:check_peers, _from, %{peers: peers} = state) do
    filtered_peers = :maps.filter(fn(_, %{uri: uri}) ->
        case Client.get_info(uri) do
          {:ok, info} ->
            info.genesis_block_hash == genesis_block_header_hash()
          _ ->
            false
        end
      end, peers)
    updated_peers =
      for {nonce, %{uri: uri, latest_block: latest_block}} <- filtered_peers, into: %{} do
        {_, info} = Client.get_info(uri)
        if info.current_block_hash != latest_block do
          {nonce, %{uri: uri, latest_block: info.current_block_hash}}
        else
          {nonce, %{uri: uri, latest_block: latest_block}}
        end
      end

    removed_peers_count = Enum.count(peers) - Enum.count(filtered_peers)
    if removed_peers_count > 0 do
      Logger.info(fn -> "#{removed_peers_count} peers were removed after the check" end)
    end

    {:reply, :ok, %{state | peers: updated_peers}}
  end

  def handle_call(:all_peers, _from, %{peers: peers} = state) do
    {:reply, peers, state}
  end

  ## Async operations
  def handle_cast({:schedule_add_peer, uri, nonce}, %{peers: peers} = state) do
    if Map.has_key?(peers, nonce) do
      {:noreply, state}
    else
      {:reply, _, newstate} = add_peer(uri, state)
      {:noreply, newstate}
    end
  end

  def handle_cast(any, state) do
    Logger.info("[Peers] Unhandled cast message:  #{inspect(any)}")
    {:noreply, state}
  end

  ## Internal functions
  defp add_peer(uri, state) do
    %{peers: peers} = state
    state_has_uri = peers
      |> Map.values()
      |> Enum.map(fn(%{uri: uri}) -> uri end)
      |> Enum.member?(uri)

    if state_has_uri do
      Logger.debug(fn ->
        "Skipped adding #{uri}, already known" end)
      {:reply, {:error, "Peer already known"}, state}
    else
      case check_peer(uri, get_peer_nonce()) do
        {:ok, info} ->
          if(!Map.has_key?(peers, info.peer_nonce)) do
            if should_a_peer_be_added(map_size(peers)) do
              peers_update1 = trim_peers(peers)
              updated_peers =
                Map.put(peers_update1, info.peer_nonce,
                        %{uri: uri, latest_block: info.current_block_hash})
              Logger.info(fn -> "Added #{uri} to the peer list" end)
              Sync.ask_peers_for_unknown_blocks(updated_peers)
              Sync.add_valid_peer_blocks_to_chain()
              #Sync.add_unknown_peer_pool_txs(updated_peers)
              {:reply, :ok, %{state | peers: updated_peers}}
            else
              Logger.debug(fn -> "Max peers reached. #{uri} not added" end)
              {:reply, :ok, state}
            end
          else
            Logger.debug(fn ->
              "Skipped adding #{uri}, same nonce already present" end)
            {:reply, {:error, "Peer already known"}, state}
          end
        {:error, "Equal peer nonces"} ->
          {:reply, :ok, state}
        {:error, reason} ->
          Logger.error(fn -> "Failed to add peer. reason=#{reason}" end)
          {:reply, {:error, reason}, state}
      end
    end
  end

  defp trim_peers(peers) do
    if map_size(peers) >= @peers_max_count do
      random_peer = Enum.random(Map.keys(peers))
      Logger.debug(fn -> "Max peers reached. #{random_peer} removed" end)
      Map.delete(peers, random_peer)
    else
      peers
    end
  end

  defp create_nonce_table() do
    :ets.new(:nonce_table, [:named_table])
  end

  defp check_peer(uri, own_nonce) do
    case(Client.get_info(uri)) do
      {:ok, info} ->
        case own_nonce == info.peer_nonce do
          false ->
            cond do
              info.genesis_block_hash != genesis_block_header_hash() ->
                {:error, "Genesis header hash not valid"}
              !Map.has_key?(info, :server) || info.server != "aehttpserver" ->
                {:error, "Peer is not an aehttpserver"}
              true ->
                {:ok, info}
            end
          true ->
            {:error, "Equal peer nonces"}
        end
      :error ->
        {:error, "Request error"}
    end
  end

  defp should_a_peer_be_added peers_count do
    peers_count < @peers_max_count
    || :rand.uniform() < @probability_of_peer_remove_when_max
  end

end
