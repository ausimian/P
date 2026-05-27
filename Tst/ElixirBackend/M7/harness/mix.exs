defmodule M7Harness.MixProject do
  use Mix.Project

  # Host project that drives the generated M7 program from ExUnit. It depends on the generated mix
  # lib (path, under ../PGenerated/Elixir) and on p_runtime. Run `p compile --mode elixir` in the
  # parent directory first, then `mix test` here.
  #
  # p_runtime is taken from the local vendored checkout via a `path` override, which overrides the
  # generated lib's own github declaration (the M7 unhandled-event/terminate helpers are not yet
  # published).
  def project do
    [
      app: :m7_harness,
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
      {:m7_demo, path: "../PGenerated/Elixir"}
    ]
  end
end
