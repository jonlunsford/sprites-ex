defmodule Sprites.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/superfly/sprites-ex"

  def project do
    [
      app: :sprites,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Sprites",
      description: "Elixir SDK for Sprites code container runtime",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :inets]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:mint, "~> 1.5"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "Sprites-Ex",
      extras: ["README.md"]
    ]
  end
end
