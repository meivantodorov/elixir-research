defmodule Aecore.Structures.Chain do

  alias Aecore.Structures.GenesisBlock
  alias Aecore.Structures.Block

  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, [GenesisBlock.genesis_block()], name: __MODULE__)
  end

  def init([%Block{}] = initial_chain) do
    {:ok, initial_chain}
  end

  def latest_block() do
    GenServer.call(__MODULE__, :latest_block)
  end

  def all_blocks() do
    GenServer.call(__MODULE__, :all_blocks)
  end

  def add_block(%Block{} = b) do
    GenServer.call(__MODULE__, {:add_block, b})
  end

  def handle_call(:latest_block, _from, chain) do
    [lb | _] = chain
    {:reply, lb, chain}
  end

  def handle_call(:all_blocks, _from, chain) do
    {:reply, chain, chain}
  end

  def handle_call({:add_block, %Block{} = b}, _from, chain) do
    #TODO validations
    {:reply, :ok, [b | chain]}
  end

end
