defmodule ZoneRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :zone_relay,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: Mix.compilers() ++ [:zone_nif],
      deps: [{:mojoler, github: "thanos/mojoler", ref: "76ec452d26d171f5a03f72d05d854f2819c29383"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
