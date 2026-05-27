defmodule M3Harness.MixProject do
  use Mix.Project

  # Host project that drives the generated M3 program from ExUnit. It depends on the generated
  # mix lib (path, under ../PGenerated/Elixir) and on p_runtime.
  #
  # p_runtime is taken from the local vendored checkout via a `path` override (M3 extends it with
  # the Spawner and id-based send resolution, which are not yet published). This overrides the
  # generated lib's own github declaration. Run `p compile --mode elixir` in the parent directory
  # first, then `mix test` here.
  def project do
    [
      app: :m3_harness,
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
      {:m3_demo, path: "../PGenerated/Elixir"}
    ]
  end
end
