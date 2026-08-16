# Fork hardening record (superseded by upstream)

Two commits on the allowed-models branch, both independently landed upstream.
Kept here as a record in case upstream regresses; do not re-apply unless upstream diverges.

## Commit 1: 5d53a60 — Restrict the web-ui model picker to the org allowed-models list
Upstream equivalent: 7893008 (PR #40)

```diff
commit 5d53a60207b72408764ed3e7cf2f9d95daa2155a
Author: Josh France <12610835+16francej@users.noreply.github.com>
Date:   Fri Jul 31 09:53:17 2026 -0700

    Restrict the web-ui model picker to the org allowed-models list
    
    The org webui-models allowlist was already durable and enforced at the
    turn endpoint, but runtime-config still advertised the full catalog, so
    the composer dropdown offered models the turn then refused as
    model_not_enabled. When the allowlist is non-empty, modelsByHarness is
    now built from it (filtered per harness); empty keeps the full catalog.
    
    The Admin governance card is rebuilt as chips with an Add model input
    searching the live catalog, replacing the per-catalog-entry checkbox
    list that could not express an OpenRouter allowlist at catalog scale.
    The first chip is the picker default.
    
    Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

diff --git a/plugins/admin/public/index.html b/plugins/admin/public/index.html
index e6b3d6f..f019ed3 100644
--- a/plugins/admin/public/index.html
+++ b/plugins/admin/public/index.html
@@ -4303,14 +4303,22 @@
                 </section>
                 <section class="card hidden" id="card-webui-models">
                   <div class="head">
-                    <h2>Web UI model picker</h2>
+                    <h2>Allowed models</h2>
                     <p>
-                      Which models appear in the web UI's per-turn model picker, org-wide. Check the ones to offer and
-                      pick which is pre-selected by default. Leave all unchecked to restore the built-in set.
+                      Restrict which models the web UI offers and accepts, org-wide. Add the models to allow and pick
+                      which is pre-selected by default. Remove every chip to allow the deployment's full model set.
                     </p>
                   </div>
                   <div class="body">
-                    <div id="webui-models-list" style="display: flex; flex-direction: column; gap: 6px"></div>
+                    <div id="webui-models-chips" style="display: flex; flex-wrap: wrap; gap: 6px; align-items: center">
+                      <input
+                        id="webui-models-add"
+                        list="webui-models-catalog"
+                        placeholder="+ Add model"
+                        style="max-width: 240px"
+                      />
+                      <datalist id="webui-models-catalog"></datalist>
+                    </div>
                     <label for="webui-models-default" style="margin-top: 10px">Default</label>
                     <select id="webui-models-default" style="max-width: 360px"></select>
                   </div>
@@ -4820,6 +4828,7 @@
       let memDraft = null;
       let memDraftScope = null;
       let cronDestinationEditId = null;
+      let webuiModelIds = [];
       const transcriptVisibility = { thinking: true, toolResults: true };
 
       const API_BASE = "__ADMIN_BASE__";
@@ -6305,48 +6314,84 @@
         const showWebuiModels = scope.startsWith("org:") && opts.length > 0;
         $("card-webui-models").classList.toggle("hidden", !showWebuiModels);
         if (showWebuiModels) {
-          const configured = Array.isArray(r.data.webuiModels) ? r.data.webuiModels : null;
-          const enabledIds = configured && configured.length ? configured : opts.map((m) => m.id);
-          const list = $("webui-models-list");
-          list.textContent = "";
-
-          const ordered = [
-            ...enabledIds.filter((id) => opts.some((m) => m.id === id)),
-            ...opts.map((m) => m.id).filter((id) => !enabledIds.includes(id)),
-          ];
-          ordered.forEach((id) => {
-            const m = opts.find((x) => x.id === id) || { id, name: id };
-            const row = document.createElement("label");
-            row.style.display = "flex";
-            row.style.gap = "8px";
-            row.style.alignItems = "center";
-            const cb = document.createElement("input");
-            cb.type = "checkbox";
-            cb.value = id;
-            cb.checked = enabledIds.includes(id);
-            const span = document.createElement("span");
-            span.textContent = m.name + " (" + id + ")";
-            row.appendChild(cb);
-            row.appendChild(span);
-            list.appendChild(row);
-          });
+          const catalogModels = Object.values(modelsByHarness)
+            .flat()
+            .concat(opts)
+            .filter((m, i, all) => m && m.id && all.findIndex((x) => x && x.id === m.id) === i);
+          const modelLabel = (id) => {
+            const m = catalogModels.find((x) => x.id === id);
+            return m && m.name && m.name !== id ? m.name + " (" + id + ")" : id;
+          };
+          const configured = Array.isArray(r.data.webuiModels) ? r.data.webuiModels.filter(Boolean) : [];
+          webuiModelIds = [...configured];
+          const chips = $("webui-models-chips");
+          const addInput = $("webui-models-add");
           const syncDefault = () => {
             const dsel = $("webui-models-default");
             const prev = dsel.value;
-            const checked = Array.from(list.querySelectorAll("input[type=checkbox]:checked")).map((c) => c.value);
             dsel.textContent = "";
-            checked.forEach((id) => {
-              const m = opts.find((x) => x.id === id) || { id, name: id };
+            webuiModelIds.forEach((id) => {
               const o = document.createElement("option");
               o.value = id;
-              o.textContent = m.name + " (" + id + ")";
+              o.textContent = modelLabel(id);
               dsel.appendChild(o);
             });
-            dsel.value = checked.includes(prev) ? prev : checked[0] || "";
+            dsel.value = webuiModelIds.includes(prev) ? prev : webuiModelIds[0] || "";
+            dsel.disabled = !webuiModelIds.length;
+          };
+          const renderChips = () => {
+            chips.querySelectorAll("[data-chip]").forEach((n) => n.remove());
+            webuiModelIds.forEach((id) => {
+              const chip = document.createElement("span");
+              chip.dataset.chip = id;
+              chip.style.cssText =
+                "display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border:1px solid var(--border, #d4d4d4);border-radius:999px;font-size:13px";
+              const label = document.createElement("span");
+              label.textContent = modelLabel(id);
+              const x = document.createElement("button");
+              x.type = "button";
+              x.textContent = "×";
+              x.setAttribute("aria-label", "Remove " + id);
+              x.style.cssText = "border:0;background:none;cursor:pointer;padding:0;font-size:14px;line-height:1";
+              x.onclick = () => {
+                webuiModelIds = webuiModelIds.filter((v) => v !== id);
+                renderChips();
+                syncDefault();
+              };
+              chip.appendChild(label);
+              chip.appendChild(x);
+              chips.insertBefore(chip, addInput);
+            });
+            const dl = $("webui-models-catalog");
+            dl.textContent = "";
+            catalogModels
+              .filter((m) => !webuiModelIds.includes(m.id))
+              .forEach((m) => {
+                const o = document.createElement("option");
+                o.value = m.id;
+                o.label = m.name;
+                dl.appendChild(o);
+              });
           };
-          list.oninput = syncDefault;
+          const addModel = () => {
+            const raw = addInput.value.trim();
+            if (!raw) return;
+            const byName = catalogModels.find((m) => m.name === raw || m.name + " (" + m.id + ")" === raw);
+            const id = catalogModels.some((m) => m.id === raw) ? raw : byName ? byName.id : raw;
+            if (!webuiModelIds.includes(id)) webuiModelIds.push(id);
+            addInput.value = "";
+            renderChips();
+            syncDefault();
+          };
+          addInput.onchange = addModel;
+          addInput.onkeydown = (e) => {
+            if (e.key === "Enter") {
+              e.preventDefault();
+              addModel();
+            }
+          };
+          renderChips();
           syncDefault();
-          $("webui-models-default").value = enabledIds[0] || "";
         }
         const showPeopleDirectory = scope.startsWith("org:");
         $("card-people-directory").classList.toggle("hidden", !showPeopleDirectory);
@@ -7731,11 +7776,9 @@
           ),
         }),
         "webui-models": () => {
-          const enabled = Array.from(document.querySelectorAll("#webui-models-list input[type=checkbox]:checked")).map(
-            (c) => c.value,
-          );
           const dflt = $("webui-models-default").value;
-          const ids = dflt && enabled.includes(dflt) ? [dflt, ...enabled.filter((id) => id !== dflt)] : enabled;
+          const ids =
+            dflt && webuiModelIds.includes(dflt) ? [dflt, ...webuiModelIds.filter((id) => id !== dflt)] : webuiModelIds;
           return { ids };
         },
         "people-directory-url": () => ({ url: $("people-directory-url").value.trim() }),
diff --git a/src/api/routes/surface.ts b/src/api/routes/surface.ts
index 0d66675..397a558 100644
--- a/src/api/routes/surface.ts
+++ b/src/api/routes/surface.ts
@@ -971,9 +971,12 @@ async function runtimeConfigBody(ctx: ApiCtx, scope: ScopeId): Promise<Record<st
   }
   const effective = scopeOverride ?? orgDefault;
   const selected = [orgDefault, scopeOverride, effective].filter((choice) => choice !== null);
+  const allowlist = await config.getWebuiModelsDurable(org);
   const modelsByHarness = Object.fromEntries(
     approvedHarnesses.map((harnessId) => {
-      const ids = selectableCatalogForHarness(catalog, harnessId).map((model) => model.id);
+      const ids = allowlist?.length
+        ? allowlist.filter((id) => modelSupportedByHarness(id, harnessId))
+        : selectableCatalogForHarness(catalog, harnessId).map((model) => model.id);
       for (const choice of selected) {
         if (
           choice.harnessId === harnessId &&
diff --git a/test/admin-resources.test.ts b/test/admin-resources.test.ts
index e900d01..e34fa31 100644
--- a/test/admin-resources.test.ts
+++ b/test/admin-resources.test.ts
@@ -240,14 +240,8 @@ test("runtime-config lets a person set, keep, and inherit an approved personal r
     };
     assert.equal(initial.effective.harnessId, "pi");
     assert.equal(initial.scopeOverride, null);
-    assert.deepEqual(initial.modelsByHarness.claude, [
-      "claude-fable-5",
-      "claude-opus-5",
-      "claude-opus-4-8",
-      "claude-sonnet-5",
-      "claude-haiku-4-5",
-    ]);
-    assert.deepEqual(initial.modelsByHarness.codex, ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]);
+    assert.deepEqual(initial.modelsByHarness.claude, ["claude-sonnet-4-6"]);
+    assert.deepEqual(initial.modelsByHarness.codex, ["gpt-5.5"]);
 
     const outsidePicker = await fetch(`${srv.base}/v1/runtime-config`, {
       method: "PUT",
diff --git a/test/webui-model-allowlist.test.ts b/test/webui-model-allowlist.test.ts
new file mode 100644
index 0000000..3632557
--- /dev/null
+++ b/test/webui-model-allowlist.test.ts
@@ -0,0 +1,72 @@
+import "./support/auto-fake-sprites.ts";
+
+import assert from "node:assert/strict";
+import type { AddressInfo } from "node:net";
+import { mkdtempSync } from "node:fs";
+import { tmpdir } from "node:os";
+import { join } from "node:path";
+import { test } from "node:test";
+import { createInsecureTestServer } from "../src/api/server.ts";
+import { buildApp } from "../src/wiring.ts";
+import { testConfig } from "./support/test-config.ts";
+
+const ADMIN = { "content-type": "application/json", "x-admin-actor": "admin-alice@default-org" };
+
+test("the org allowed-models list restricts the runtime-config picker and clearing restores the catalog", async () => {
+  const modelCredentialFetch: typeof fetch = async () =>
+    Response.json({
+      data: [
+        { id: "anthropic/claude-sonnet-4.5", name: "Anthropic: Claude Sonnet 4.5", supported_parameters: ["tools"] },
+        { id: "deepseek/deepseek-chat-v3.1", name: "DeepSeek: DeepSeek V3.1", supported_parameters: ["tools"] },
+      ],
+    });
+  const built = buildApp(
+    testConfig({
+      dataDir: mkdtempSync(join(tmpdir(), "webui-model-allowlist-")),
+      openrouterApiKey: "deployment-openrouter-key",
+    }),
+    { modelCredentialFetch },
+  );
+  const server = createInsecureTestServer(built.app, {
+    config: built.config,
+    modelCredentials: built.modelCredentials,
+    modelCredentialFetch,
+    harnessId: "pi",
+    providerKeys: { anthropic: false, openai: false, openrouter: true },
+    admin: built.admin,
+    auditLog: built.auditLog,
+  });
+  server.listen(0);
+  const base = `http://localhost:${(server.address() as AddressInfo).port}`;
+  const runtimeModels = async (): Promise<string[]> => {
+    const response = await fetch(`${base}/v1/runtime-config?principalId=alice&scopeId=personal%3Aalice`);
+    assert.equal(response.status, 200);
+    return ((await response.json()) as { modelsByHarness: Record<string, string[]> }).modelsByHarness.pi!;
+  };
+  try {
+    const unrestricted = await runtimeModels();
+    assert.ok(unrestricted.includes("anthropic/claude-sonnet-4.5"));
+    assert.ok(unrestricted.includes("deepseek/deepseek-chat-v3.1"));
+
+    const saved = await fetch(`${base}/v1/admin/scopes/org%3Adefault-org/webui-models`, {
+      method: "PUT",
+      headers: ADMIN,
+      body: JSON.stringify({ ids: ["deepseek/deepseek-chat-v3.1", "openrouter/auto"] }),
+    });
+    assert.equal(saved.status, 200);
+
+    assert.deepEqual(await runtimeModels(), ["deepseek/deepseek-chat-v3.1", "openrouter/auto"]);
+
+    const cleared = await fetch(`${base}/v1/admin/scopes/org%3Adefault-org/webui-models`, {
+      method: "PUT",
+      headers: ADMIN,
+      body: JSON.stringify({ ids: [] }),
+    });
+    assert.equal(cleared.status, 200);
+    const restored = await runtimeModels();
+    assert.ok(restored.includes("anthropic/claude-sonnet-4.5"));
+    assert.ok(restored.includes("deepseek/deepseek-chat-v3.1"));
+  } finally {
+    await new Promise<void>((resolve) => server.close(() => resolve()));
+  }
+});
```

## Commit 2: 04b909a — Harden the allowed-models picker paths found in adversarial review
Upstream equivalent: per-harness selectability in model-catalog.ts + surface.ts

```diff
commit 04b909a93393e2908e57f7d3084fad724e4c4fbc
Author: Josh France <12610835+16francej@users.noreply.github.com>
Date:   Fri Jul 31 10:16:18 2026 -0700

    Harden the allowed-models picker paths found in adversarial review
    
    Allowlisted OpenRouter ids no longer leak into harnesses the catalog
    excludes them from: the picker filter now shares the catalog's
    per-harness selectability predicate instead of only checking name
    support, so openai/-prefixed OpenRouter models stop being advertised to
    the native Codex harness.
    
    A harness whose allowlist intersection is empty now contributes no
    picker options; the web-ui fallback to built-in defaults applies only
    when the core sent no list at all or every sent id is unknown to the
    bundle (version skew), so a restriction can no longer resurface the
    full catalog client-side.
    
    Chip add and remove in the admin card dispatch the section dirty event,
    so Save enables and the unsaved-changes warning fires for removals.
    
    webuiModels joins flushScope and refreshScope: admin saves flush the
    allowlist write before returning, and blue-green peers reload it on
    scope refresh instead of serving and overwriting stale process caches.
    
    Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

diff --git a/plugins/admin/public/index.html b/plugins/admin/public/index.html
index f019ed3..a184000 100644
--- a/plugins/admin/public/index.html
+++ b/plugins/admin/public/index.html
@@ -6326,6 +6326,7 @@
           webuiModelIds = [...configured];
           const chips = $("webui-models-chips");
           const addInput = $("webui-models-add");
+          const markDirty = () => addInput.dispatchEvent(new Event("input", { bubbles: true }));
           const syncDefault = () => {
             const dsel = $("webui-models-default");
             const prev = dsel.value;
@@ -6357,6 +6358,7 @@
                 webuiModelIds = webuiModelIds.filter((v) => v !== id);
                 renderChips();
                 syncDefault();
+                markDirty();
               };
               chip.appendChild(label);
               chip.appendChild(x);
@@ -6382,6 +6384,7 @@
             addInput.value = "";
             renderChips();
             syncDefault();
+            markDirty();
           };
           addInput.onchange = addModel;
           addInput.onkeydown = (e) => {
diff --git a/plugins/web-ui/src/model-options.ts b/plugins/web-ui/src/model-options.ts
index 3a6f4a4..04549ff 100644
--- a/plugins/web-ui/src/model-options.ts
+++ b/plugins/web-ui/src/model-options.ts
@@ -144,7 +144,9 @@ export function applyRuntimeOptions(
   catalog: Readonly<Record<string, { name: string; provider: string }>> = {},
 ): void {
   activeModelOptions = approvedHarnesses.flatMap((harnessId) => {
-    const configured = buildOptions(modelsByHarness[harnessId] ?? [], harnessId, true, catalog);
+    const ids = modelsByHarness[harnessId];
+    if (ids && ids.length === 0) return [];
+    const configured = buildOptions(ids ?? [], harnessId, true, catalog);
     return configured.length
       ? configured
       : buildOptions(defaultModelIdsForHarness(harnessId), harnessId, true, catalog);
diff --git a/plugins/web-ui/test/model-options.test.ts b/plugins/web-ui/test/model-options.test.ts
index 4c3ba48..b2ccc05 100644
--- a/plugins/web-ui/test/model-options.test.ts
+++ b/plugins/web-ui/test/model-options.test.ts
@@ -122,6 +122,19 @@ test("harness-only turn controls are exposed only where the adapter supports the
   assert.equal(harnessSupportsFastMode("opencode"), false);
 });
 
+test("a harness the org allowlist empties contributes no options instead of the built-in set", () => {
+  applyRuntimeOptions(
+    ["pi", "codex"],
+    { pi: ["claude-fable-5"], codex: [] },
+    { harnessId: "pi", modelId: "claude-fable-5" },
+  );
+  assert.deepEqual(getModelOptionsForHarness("codex"), []);
+  assert.deepEqual(
+    getModelOptionsForHarness("pi").map((o) => o.value),
+    ["pi:claude-fable-5"],
+  );
+});
+
 test("an all-retired list falls back within the approved harness", () => {
   applyRuntimeOptions(["codex"], { codex: ["gpt-5.5"] }, { harnessId: "codex", modelId: "gpt-5.5" });
   assert.deepEqual(getHarnessOptions(), [{ value: "codex", label: "Codex" }]);
diff --git a/src/api/routes/surface.ts b/src/api/routes/surface.ts
index 397a558..a358dcb 100644
--- a/src/api/routes/surface.ts
+++ b/src/api/routes/surface.ts
@@ -13,7 +13,12 @@ import {
   FAST_MODE_MODEL_IDS,
   type HarnessId,
 } from "../../model/pi-models.ts";
-import { builtInModelCatalog, selectableCatalogForHarness, selectableModelCatalog } from "../../model/model-catalog.ts";
+import {
+  builtInModelCatalog,
+  modelSelectableForHarness,
+  selectableCatalogForHarness,
+  selectableModelCatalog,
+} from "../../model/model-catalog.ts";
 import { errMessage } from "../../util/errors.ts";
 import { renderAgentApis } from "../agent-api-catalog.ts";
 import { mintCapabilityToken, CAPABILITY_TTL_MS } from "../../auth/capability-token.ts";
@@ -975,7 +980,7 @@ async function runtimeConfigBody(ctx: ApiCtx, scope: ScopeId): Promise<Record<st
   const modelsByHarness = Object.fromEntries(
     approvedHarnesses.map((harnessId) => {
       const ids = allowlist?.length
-        ? allowlist.filter((id) => modelSupportedByHarness(id, harnessId))
+        ? allowlist.filter((id) => modelSelectableForHarness(id, harnessId))
         : selectableCatalogForHarness(catalog, harnessId).map((model) => model.id);
       for (const choice of selected) {
         if (
diff --git a/src/model/model-catalog.ts b/src/model/model-catalog.ts
index 812d69c..1fdf0b4 100644
--- a/src/model/model-catalog.ts
+++ b/src/model/model-catalog.ts
@@ -100,13 +100,16 @@ export async function selectableModelCatalog(fetcher: typeof fetch = fetch): Pro
   return entry.inFlight;
 }
 
+export function modelSelectableForHarness(id: string, harness: string): boolean {
+  return (
+    (resolveModel(id)?.provider !== "openrouter" || harness === "pi" || harness === "mock") &&
+    modelSupportedByHarness(id, harness)
+  );
+}
+
 export function selectableCatalogForHarness(
   catalog: readonly ModelCatalogEntry[],
   harness: string,
 ): ModelCatalogEntry[] {
-  return catalog.filter(
-    (model) =>
-      (model.provider !== "openrouter" || harness === "pi" || harness === "mock") &&
-      modelSupportedByHarness(model.id, harness),
-  );
+  return catalog.filter((model) => modelSelectableForHarness(model.id, harness));
 }
diff --git a/src/resolution/config-store.ts b/src/resolution/config-store.ts
index cba1a0e..76b926e 100644
--- a/src/resolution/config-store.ts
+++ b/src/resolution/config-store.ts
@@ -875,6 +875,7 @@ export function createMemoryConfigStore(
         brandingRow,
         orgAmbientRow,
         interactiveFastModeRow,
+        webuiModelsRow,
       ] = await Promise.all([
         soulStore.get(id),
         commandPolicyStore.get(id),
@@ -888,6 +889,7 @@ export function createMemoryConfigStore(
         brandingStore.get(id),
         id === org ? orgAmbientStore.get(org) : null,
         id === org ? interactiveFastModeStore.get(org) : null,
+        webuiModelStore.get(id),
       ]);
       let refreshedSoul = soul;
       const legacyHistory = legacySoulHistory.get(id) ?? [];
@@ -926,6 +928,8 @@ export function createMemoryConfigStore(
       if (id === org) approvedHarnesses = approved?.ids ?? null;
       if (id === org) orgAmbient = orgAmbientRow?.on ?? true;
       if (id === org) interactiveFastMode = interactiveFastModeRow?.on ?? false;
+      if (webuiModelsRow) webuiModels.set(id, webuiModelsRow.ids);
+      else webuiModels.delete(id);
       if (brandingRow) branding.set(id, brandingRow.branding);
       else branding.delete(id);
     },
@@ -940,6 +944,7 @@ export function createMemoryConfigStore(
         `model:${id}`,
         `turnWallClock:${id}`,
         `branding:${id}`,
+        `webuiModels:${id}`,
         ...(id === org ? [`approvedHarnesses:${org}`, `orgAmbient:${org}`, `interactiveFastMode:${org}`] : []),
       ];
       await Promise.all(
diff --git a/test/webui-model-allowlist.test.ts b/test/webui-model-allowlist.test.ts
index 3632557..d2ed730 100644
--- a/test/webui-model-allowlist.test.ts
+++ b/test/webui-model-allowlist.test.ts
@@ -38,11 +38,12 @@ test("the org allowed-models list restricts the runtime-config picker and cleari
   });
   server.listen(0);
   const base = `http://localhost:${(server.address() as AddressInfo).port}`;
-  const runtimeModels = async (): Promise<string[]> => {
+  const runtimeModelsByHarness = async (): Promise<Record<string, string[]>> => {
     const response = await fetch(`${base}/v1/runtime-config?principalId=alice&scopeId=personal%3Aalice`);
     assert.equal(response.status, 200);
-    return ((await response.json()) as { modelsByHarness: Record<string, string[]> }).modelsByHarness.pi!;
+    return ((await response.json()) as { modelsByHarness: Record<string, string[]> }).modelsByHarness;
   };
+  const runtimeModels = async (): Promise<string[]> => (await runtimeModelsByHarness()).pi!;
   try {
     const unrestricted = await runtimeModels();
     assert.ok(unrestricted.includes("anthropic/claude-sonnet-4.5"));
@@ -57,6 +58,13 @@ test("the org allowed-models list restricts the runtime-config picker and cleari
 
     assert.deepEqual(await runtimeModels(), ["deepseek/deepseek-chat-v3.1", "openrouter/auto"]);
 
+    built.config.setApprovedHarnesses(["pi", "codex"]);
+    built.config.setWebuiModels("org:default-org", ["deepseek/deepseek-chat-v3.1", "openai/gpt-5.6-luna"]);
+    await built.config.flushScope("org:default-org");
+    const byHarness = await runtimeModelsByHarness();
+    assert.deepEqual(byHarness.pi, ["deepseek/deepseek-chat-v3.1", "openai/gpt-5.6-luna"]);
+    assert.ok(!byHarness.codex!.includes("openai/gpt-5.6-luna"));
+
     const cleared = await fetch(`${base}/v1/admin/scopes/org%3Adefault-org/webui-models`, {
       method: "PUT",
       headers: ADMIN,
```
