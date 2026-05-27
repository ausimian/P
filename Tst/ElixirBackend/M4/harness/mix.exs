defmodule M4Harness.MixProject do
  use Mix.Project

  # Host project that drives the generated M4 program from ExUnit. It depends on the generated
  # mix lib (path, under ../PGenerated/Elixir) and on p_runtime.
  #
  # p_runtime is taken from the local vendored checkout via a `path` override (M4 extends it with
  # the defer/ignore/raise_event helpers, which are not yet published). This overrides the
  # generated lib's own github declaration. Run `p compile --mode elixir` in the parent directory
  # first, then `mix test` here.
  def project do
    [
      app: :m4_harness,
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
      {:m4_demo, path: "../PGenerated/Elixir"}
    ]
  end
end
