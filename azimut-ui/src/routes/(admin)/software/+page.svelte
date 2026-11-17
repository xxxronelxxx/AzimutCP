<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { api } from '$api/client';

  type VersionStatus = {
    version: string;
    installed: boolean;
    in_use: number;
    error: string | null;
  };

  type SoftwareItem = {
    id: string;
    name: string;
    category: string;
    description: string;
    removable: boolean;
    versions: VersionStatus[];
  };

  let items: SoftwareItem[] = [];
  let loading = true;
  let loadError = '';
  let busy = '';
  let message = '';
  let pollTimer: ReturnType<typeof setInterval> | null = null;

  $: groups = (() => {
    const map = new Map<string, SoftwareItem[]>();
    for (const item of items) {
      const list = map.get(item.category) ?? [];
      list.push(item);
      map.set(item.category, list);
    }
    return Array.from(map.entries());
  })();

  onMount(async () => {
    await load();
  });

  onDestroy(() => {
    if (pollTimer) clearInterval(pollTimer);
  });

  async function load() {
    try {
      items = await api.software.list();
      loadError = '';
    } catch (err: unknown) {
      loadError = (err as { message?: string })?.message ?? 'Failed to load the software catalog';
    } finally {
      loading = false;
    }
  }

  function startPolling() {
    if (pollTimer) return;
    let ticks = 0;
    pollTimer = setInterval(async () => {
      ticks += 1;
      await load();
      const stillRunning = items.some(item =>
        item.versions.some(v => !v.installed && busy === `${item.id}:${v.version}`)
      );
      if (!stillRunning || ticks >= 60) {
        if (pollTimer) clearInterval(pollTimer);
        pollTimer = null;
        busy = '';
      }
    }, 5000);
  }

  async function install(item: SoftwareItem, version: string) {
    if (busy) return;
    busy = `${item.id}:${version}`;
    message = `Installing ${item.name} ${version}…`;
    try {
      await api.software.install(item.id, version);
      startPolling();
    } catch (err: unknown) {
      const e = err as { message?: string; error?: string };
      message = e.message ?? e.error ?? `Failed to install ${item.name}`;
      busy = '';
    }
  }

  async function remove(item: SoftwareItem, version: string) {
    if (busy) return;
    if (!confirm(`Remove ${item.name} ${version}? This may delete its packages; data directories are kept.`)) {
      return;
    }
    busy = `${item.id}:${version}`;
    message = `Removing ${item.name} ${version}…`;
    try {
      await api.software.uninstall(item.id, version);
      startPolling();
    } catch (err: unknown) {
      const e = err as { message?: string; error?: string };
      message = e.message ?? e.error ?? `Failed to remove ${item.name}`;
      busy = '';
    }
  }

  function label(item: SoftwareItem, v: VersionStatus): string {
    if (v.version === 'latest') return item.name;
    return `${item.name} ${v.version}`;
  }
</script>

<svelte:head>
  <title>Server Software — AzimutCP</title>
</svelte:head>

<div class="p-6 space-y-6">
  <div>
    <h1 class="text-xl font-semibold text-foreground">Server Software</h1>
    <p class="text-sm text-muted-foreground mt-1">
      Install and remove PHP versions, database servers, caches, runtimes and tools.
      Operations run through the system package manager and can take a few minutes.
    </p>
  </div>

  {#if message}
    <div class="rounded-lg border border-border bg-card px-4 py-3 text-sm text-foreground">
      {message}
    </div>
  {/if}

  {#if loadError}
    <div class="rounded-lg border border-red-500/30 bg-red-500/10 px-4 py-3 text-sm text-red-400">
      {loadError}
    </div>
  {/if}

  {#if loading}
    <p class="text-sm text-muted-foreground">Loading catalog…</p>
  {:else}
    {#each groups as [category, list]}
      <section class="space-y-3">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-muted-foreground">{category}</h2>

        <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
          {#each list as item}
            <div class="rounded-xl border border-border bg-card p-4 flex flex-col gap-3">
              <div>
                <h3 class="text-sm font-semibold text-foreground">{item.name}</h3>
                <p class="text-xs text-muted-foreground mt-0.5">{item.description}</p>
              </div>

              <div class="space-y-1.5">
                {#each item.versions as v}
                  {@const key = `${item.id}:${v.version}`}
                  <div class="flex items-center justify-between gap-2 text-xs">
                    <span class="font-mono text-foreground">{label(item, v)}</span>

                    {#if v.installed}
                      <span class="text-green-400">
                        Installed{v.in_use > 0 ? ` · ${v.in_use} in use` : ''}
                      </span>
                      {#if item.removable}
                        <button
                          type="button"
                          class="text-red-400 hover:text-red-300 disabled:opacity-50"
                          disabled={!!busy}
                          on:click={() => remove(item, v.version)}
                        >
                          {busy === key ? 'Working…' : 'Remove'}
                        </button>
                      {:else}
                        <span class="text-muted-foreground">panel dependency</span>
                      {/if}
                    {:else}
                      <button
                        type="button"
                        class="text-indigo-400 hover:text-indigo-300 disabled:opacity-50"
                        disabled={!!busy}
                        on:click={() => install(item, v.version)}
                      >
                        {busy === key ? 'Working…' : 'Install'}
                      </button>
                    {/if}
                  </div>

                  {#if v.error}
                    <p class="text-[10px] leading-tight text-red-400 line-clamp-2" title={v.error}>
                      {v.error}
                    </p>
                  {/if}
                {/each}
              </div>
            </div>
          {/each}
        </div>
      </section>
    {/each}
  {/if}
</div>
