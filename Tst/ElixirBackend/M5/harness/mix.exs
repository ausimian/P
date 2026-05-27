defmodule M5Harness.MixProject do
  use Mix.Project

  # Host project that drives the generated M5 program from ExUnit. It depends on the generated
  # mix lib (path, under ../PGenerated/Elixir) and on p_runtime.
  #
  # p_runtime is taken from the local vendored checkout via a `path` override (M5 extends it with
  # the spec fan-out, `announce`, `observes` and structured logging, which are not yet published).
  # This overrides the generated lib's own github declaration. Run `p compile --mode elixir` in the
  # parent directory first, then `mix test` here.
  def project do
    [
      app: :m5_harness,
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
      {:m5_demo, path: "../PGenerated/Elixir"}
    ]
  end
end
