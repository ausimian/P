defmodule M6Harness.MixProject do
  use Mix.Project

  # Host project that drives the generated M6 program from ExUnit. It depends on the generated
  # mix lib (path, under ../PGenerated/Elixir) and on p_runtime, and it supplies the hand-written
  # `PForeign` module the generated code calls (lib/p_foreign.ex) — exactly the role the generated
  # FOREIGN.md describes for a host application.
  #
  # p_runtime is taken from the local vendored checkout via a `path` override. This overrides the
  # generated lib's own github declaration. Run `p compile --mode elixir` in the parent directory
  # first, then `mix test` here.
  def project do
    [
      app: :m6_harness,
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
      {:m6_demo, path: "../PGenerated/Elixir"}
    ]
  end
end
