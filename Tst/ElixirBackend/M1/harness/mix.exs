defmodule M1Harness.MixProject do
  use Mix.Project

  # Host project that drives the generated M1 program from ExUnit. It depends on the generated
  # mix lib (path, under ../PGenerated/Elixir) and on the vendored p_runtime via a `path` override
  # (overriding the generated lib's github declaration), so the harness tracks local runtime work.
  #
  # Run `p compile --mode elixir` in the parent directory first, then `mix test` here.
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
      {:p_runtime, path: "~/Code/p_runtime" |> Path.expand(), override: true},
      {:m1_demo, path: "../PGenerated/Elixir"}
    ]
  end
end
