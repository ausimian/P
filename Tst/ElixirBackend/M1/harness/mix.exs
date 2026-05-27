defmodule M1Harness.MixProject do
  use Mix.Project

  # Host project that drives the generated M1 program from ExUnit. It depends on the generated
  # mix lib (path, under ../PGenerated/Elixir) and on p_runtime pinned to the exact commit the
  # generated lib declares (overriding the generated lib's identical declaration).
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
      {:p_runtime, github: "ausimian/p_runtime", ref: "85d4291f00612a52beada10aef9a99f45363fa60", override: true},
      {:m1_demo, path: "../PGenerated/Elixir"}
    ]
  end
end
