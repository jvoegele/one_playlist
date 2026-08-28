defmodule Mix.Tasks.Contracts.Audit do
  @shortdoc "Reports which public functions carry a Bond contract, and which carry none"

  @moduledoc """
  Which public functions have a Bond contract, and which have none.

  The one thing `Bond.Coverage` structurally cannot tell you. Its table reports
  assertions that **ran**, so it is a report about contracts that exist; a
  function nobody contracted appears nowhere in it, and neither does the module
  it lives in.

  That matters because under-contracting is the failure mode the
  `writing-bond-contracts` skill singles out as the dangerous one, on the grounds
  that it is invisible:

  > The failure mode is one-sided: a codebase with too few contracts looks
  > exactly like one that never needed them, so careful screening
  > under-contracts by default and nobody notices.

  This turns that into a number.

      mix contracts.audit                 # the summary
      mix contracts.audit --verbose       # and every uncontracted function
      mix contracts.audit --only tidal    # restrict to matching paths
      mix contracts.audit --min 40        # exit 1 below 40%, for a ratchet

  ## What it counts, and what it deliberately does not

  The denominator is **public, non-callback functions in modules that `use Bond`**
  — a `def` that is not preceded by `@impl`. Three exclusions, each for a reason:

    * A module that does not `use Bond` cannot carry a contract, so counting its
      functions would measure the wrong thing. Adding `use Bond` to a module is a
      separate decision from contracting a function in it.
    * `defp` is reported but not counted. Private functions can and do carry
      contracts here; they are not part of a module's promise to its callers, so
      a density over them measures something else.
    * `@impl` callbacks are counted separately. What a callback promises is the
      *behaviour's* to state — see `Bond.Behaviour` — so their absence from a
      module's own contracts is not the same finding.

  A module-level `@invariant` is reported apart from the per-function count.
  Bond checks it around every public function of its module, so it is real
  coverage; but it is a law about the *type*, not a promise about any one
  function, and collapsing the two would flatter the number.

  ## It is a prompt, not a verdict

  A bare function is a **question** — "what does this promise?" — and some honest
  answers are "nothing beyond its `@spec`". The skill's list of valid reasons to
  decline is short (unsound, unreachable, not warranted by the specification) and
  none of them is "there are a lot of them", so a large count here is a backlog
  rather than a defect. Read `docs/reference/contracts.md` before working through
  one.
  """

  use Mix.Task

  # Everything `use Bond` adds that attaches a contract to the *next* function.
  @attaches ~w(pre post pre_weaken post_strengthen apply_contract)a

  # Module-level laws. Written once anywhere in the module and checked around all
  # of its public functions, so they are counted per module rather than per `def`.
  @module_laws ~w(invariant state_invariant transition_invariant)a

  # Only a definition ends a pending contract. `@doc` and `@spec` routinely sit
  # between a `@pre` and the `def` it belongs to.
  @definitions ~w(def defp defmacro defmacrop defdelegate)a

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [verbose: :boolean, only: :string, min: :integer])

    modules =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> filter(opts[:only])
      |> Enum.flat_map(&scan/1)
      |> Enum.sort_by(&{-bare_count(&1), &1.path})

    report(modules, opts)
    ratchet(modules, opts[:min])
  end

  defp filter(paths, nil), do: paths
  defp filter(paths, pattern), do: Enum.filter(paths, &String.contains?(&1, pattern))

  # ── reading the source ────────────────────────────────────────────────────

  defp scan(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted()
    |> case do
      {:ok, ast} -> ast |> defmodules() |> Enum.flat_map(&analyse(&1, path))
      # A file this cannot parse is reported rather than skipped: silence here
      # would read exactly like a file with nothing to find.
      {:error, _reason} -> [%{path: path, module: "(unparseable)", functions: [], laws: 0}]
    end
  end

  defp defmodules(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [name, [do: body]]} = node, acc -> {node, [{name, body} | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(found)
  end

  defp analyse({name, body}, path) do
    statements = statements(body)

    if uses_bond?(statements) do
      [
        %{
          path: path,
          module: module_name(name),
          functions: functions(statements),
          laws: Enum.count(statements, &module_law?/1)
        }
      ]
    else
      []
    end
  end

  defp statements({:__block__, _meta, stmts}), do: stmts
  defp statements(single), do: [single]

  defp module_name({:__aliases__, _meta, parts}), do: Enum.map_join(parts, ".", &to_string/1)
  defp module_name(other), do: Macro.to_string(other)

  defp uses_bond?(statements) do
    Enum.any?(statements, fn
      {:use, _meta, [{:__aliases__, _, [:Bond | _]} | _]} -> true
      _other -> false
    end)
  end

  defp module_law?({:@, _meta, [{attr, _, _}]}), do: attr in @module_laws
  defp module_law?(_other), do: false

  # Walks a module body in order, carrying whatever contract or `@impl` is
  # waiting for the next definition. Nested modules are skipped here because
  # `defmodules/1` has already collected them in their own right.
  defp functions(statements) do
    statements
    |> Enum.reduce({[], false, false}, &visit/2)
    |> elem(0)
    |> Enum.reverse()
    |> merge_clauses()
  end

  defp visit({:defmodule, _meta, _args}, acc), do: acc

  defp visit({:@, _meta, [{:impl, _, _}]}, {found, contract?, _impl?}),
    do: {found, contract?, true}

  defp visit({:@, _meta, [{attr, _, _}]}, {found, contract?, impl?}),
    do: {found, contract? or attr in @attaches, impl?}

  defp visit({definition, _meta, [head | _rest]}, {found, contract?, impl?})
       when definition in @definitions do
    entry = %{
      name: name_and_arity(head),
      public?: definition in [:def, :defmacro],
      callback?: impl?,
      contract?: contract?
    }

    {[entry | found], false, false}
  end

  defp visit(_other, acc), do: acc

  defp name_and_arity({:when, _meta, [head | _guards]}), do: name_and_arity(head)
  defp name_and_arity({name, _meta, args}) when is_list(args), do: {name, length(args)}
  defp name_and_arity({name, _meta, _nil_args}), do: {name, 0}
  defp name_and_arity(_other), do: {:unknown, 0}

  # Several clauses are one function. Contracted if *any* of them carries the
  # contract, which is how Bond attaches one — usually on a bodiless head above
  # the clauses.
  defp merge_clauses(entries) do
    entries
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, clauses} ->
      %{
        name: name,
        public?: Enum.any?(clauses, & &1.public?),
        callback?: Enum.any?(clauses, & &1.callback?),
        contract?: Enum.any?(clauses, & &1.contract?)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  # ── reporting ─────────────────────────────────────────────────────────────

  defp counted(module), do: Enum.filter(module.functions, &(&1.public? and not &1.callback?))
  defp bare(module), do: Enum.reject(counted(module), & &1.contract?)
  defp bare_count(module), do: length(bare(module))

  defp report([], _opts), do: Mix.shell().info("No modules using Bond were found.")

  defp report(modules, opts) do
    total = modules |> Enum.flat_map(&counted/1) |> length()
    held = modules |> Enum.flat_map(&counted/1) |> Enum.count(& &1.contract?)
    callbacks = modules |> Enum.flat_map(& &1.functions) |> Enum.count(& &1.callback?)
    laws = Enum.sum_by(modules, & &1.laws)

    Mix.shell().info("""

    Bond contract density — #{length(modules)} modules using Bond

      Public, non-callback functions. A module `@invariant` is counted apart: it
      holds for every public function of its module, but it is a law about the
      type rather than a promise about any one function.
    """)

    modules
    |> Enum.reject(&(counted(&1) == []))
    |> Enum.each(fn module ->
      Mix.shell().info(line(module))
      if opts[:verbose], do: Enum.each(bare(module), &Mix.shell().info(detail(&1)))
    end)

    Mix.shell().info("""
      #{String.duplicate("─", 64)}
      #{String.pad_trailing("overall", 46)}#{tally(held, total)}

      #{total - held} of #{total} carry no contract of their own.
      #{laws} module invariant(s); #{callbacks} @impl callback(s) counted separately.
    #{hint(opts[:verbose])}\
    """)
  end

  defp hint(true), do: ""
  defp hint(_not_verbose), do: "\n  --verbose lists every uncontracted function.\n"

  defp line(module) do
    "  " <>
      String.pad_trailing(module.path, 44) <> tally(held_count(module), length(counted(module)))
  end

  defp held_count(module), do: Enum.count(counted(module), & &1.contract?)

  defp detail(%{name: {name, arity}}), do: "        #{name}/#{arity}"

  defp tally(held, total) do
    percent = if total == 0, do: 0, else: round(held / total * 100)

    String.pad_leading("#{held}/#{total}", 9) <> String.pad_leading("#{percent}%", 6)
  end

  # ── the optional ratchet ──────────────────────────────────────────────────

  defp ratchet(_modules, nil), do: :ok

  defp ratchet(modules, minimum) do
    counted = Enum.flat_map(modules, &counted/1)
    total = length(counted)
    held = Enum.count(counted, & &1.contract?)
    percent = if total == 0, do: 100, else: round(held / total * 100)

    if percent < minimum do
      Mix.raise("contract density is #{percent}%, below the required #{minimum}%")
    end

    :ok
  end
end
