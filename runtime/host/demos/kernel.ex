defmodule Workbooks.Demos.Kernel do
  @moduledoc "Demos for the OQL kernel: parse, tangle, validate, upgrade, render, conformance."

  @sample """
  * TODO Build the clean room
    :PROPERTIES:
    :ID: wb-1
    :END:
  * DONE Prove OQL runs inside the Instance host
    :PROPERTIES:
    :ID: wb-2
    :END:
  * TODO Rewrite OQL opinionated
    :PROPERTIES:
    :ID: wb-3
    :END:
  """

  @doc "Smoke demo: parse Org through the OQL kernel (oql.wasm) under the BEAM."
  def demo, do: Workbooks.OQL.parse_headlines(@sample)

  # A literate workflow scheduled with a native Org timestamp + repeater.
  @literate """
  * Nightly digest                                    :workflow:
    SCHEDULED: <2026-06-06 Sat 06:00 +1d>
  ** Fetch events                                     :component:
     #+begin_src rust :deps tokio@1.35,serde@1 :uses workbook:vfs/query :out events:list
     // query the Workbook VFS
     #+end_src
  ** Summarize                                        :component:
     #+begin_src js :in events:list :uses workbook:llm/complete :out summary:string
     export default (events) => llm.complete("summarize", events);
     #+end_src
  ** Send                                             :component:
     #+begin_src go :in summary:string :uses workbook:net/email
     // email the summary
     #+end_src
  """

  # Same workflow, but "Summarize" expects an input nobody produces.
  @broken """
  * Broken workflow                                   :workflow:
  ** Summarize                                        :component:
     #+begin_src js :in events:list :out summary:string
     export default (e) => e;
     #+end_src
  ** Send                                             :component:
     #+begin_src go :in summary:string
     // no source language problem is caught too
     #+end_src
  """

  @doc "Tangle demo: emit the WIT-world build plan (schedule + DAG + imports)."
  def demo_tangle, do: Workbooks.OQL.tangle_plan(@literate)

  @doc "Validation demo: catch a dangling input before it ever builds."
  def demo_validate, do: Workbooks.OQL.validate(@broken)

  # The deployed Workbook...
  @v1 """
  * Report                                            :workflow:
  ** Build                                            :component:
     #+begin_src rust :out report:string
     // build the report
     #+end_src
  """

  # ...and a new version that changes the output type + adds a capability.
  @v2 """
  * Report                                            :workflow:
  ** Build                                            :component:
     #+begin_src rust :uses workbook:net/email :out report:json
     // build the report, now emails it
     #+end_src
  """

  @doc "Upgrade-gate demo: refuse a breaking change before it deploys (Motoko-style)."
  def demo_upgrade, do: Workbooks.OQL.check_upgrade(@v1, @v2)

  # A workflow whose middle task is itself a sub-workflow (recursion).
  @nested """
  * Pipeline                                          :workflow:
  ** Ingest                                           :component:
     #+begin_src rust :out raw:bytes
     #+end_src
  ** Transform                                        :workflow:
  *** Clean                                           :component:
      #+begin_src js :in raw:bytes :out clean:json
      #+end_src
  *** Score                                           :component:
      #+begin_src rust :in clean:json :out score:f64
      #+end_src
  ** Publish                                          :component:
     #+begin_src go :in raw:bytes
     #+end_src
  """

  @doc "Recursion demo: a workflow with a nested sub-workflow → one nested DAG."
  def demo_nested, do: Workbooks.OQL.tangle_plan(@nested)["worlds"] |> hd()

  @persist_wf """
  * Agent                                             :workflow:
  ** Remember                                         :component:
     #+begin_src rust :persist :out memory:json
     #+end_src
  ** Act                                              :component:
     #+begin_src js :in memory:json
     #+end_src
  """

  @doc "Persistence demo: which components declared :persist (survive redeploy)."
  def demo_persist, do: Workbooks.Lifecycle.durable_components(Workbooks.OQL.tangle_plan(@persist_wf))

  @doc "Render demo: the literate Workbook to HTML (the readable side)."
  def demo_render, do: Workbooks.OQL.render(@literate)

  @doc """
  Conformance demo (wb-11ck.15): the engine-probe component conforms to
  workbooks:engine (exports run, imports only Dock funcs), so it passes; the OQL
  kernel is a different world (no `run` export), so it's correctly rejected.
  """
  def demo_conformance do
    %{
      engine_probe: Workbooks.Conformance.engine?("build/fixtures/engine-probe.wasm"),
      oql_kernel: Workbooks.Conformance.engine?("build/oql.wasm")
    }
  end
end
