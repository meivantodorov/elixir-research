defmodule Aehttpserver.Router do
  use Aehttpserver.Web, :router

  pipeline :api do
    plug CORSPlug, [origin: "*"]
    plug :accepts, ["json"]
  end

  scope "/", Aehttpserver do
    pipe_through :api

    get "/info", InfoController, :info
    post "/new_tx", NewTxController, :new_tx
    get "/peers", PeersController, :info
    post "/new_block", BlockController, :new_block
    resources "/block", BlockController, param: "hash", only: [:show]
    resources "/balance", BalanceController, param: "account", only: [:show]
    resources "/tx_pool", TxPoolController, param: "account", only: [:show]
  end


  # Other scopes may use custom stacks.
  # scope "/api", Aehttpserver do
  #   pipe_through :api
  # end
end
