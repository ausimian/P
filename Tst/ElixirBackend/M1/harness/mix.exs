defmodule M1Harness.MixProject do
  use Mix.Project

  # Host project that drives the generated M1 program from ExUnit. It depends on the generated
  # mix lib (path, under ../PGenerated/Elixir) and on p_runtime from GitHub — the same source the
  # generated lib declares.
  #
  # Run `p compile --mode elixir` in the parent directory first, then `mix test` here
  # (the first run fetches p_runtime from GitHub).
  def project do
    [
      app: :m1_harness,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Same GitHub source the generated lib declares, so the two converge.
      {:p_runtime, github: "ausimian/p_runtime"},
      {:m1_demo, path: "../PGenerated/Elixir"}
    ]
  end
end
