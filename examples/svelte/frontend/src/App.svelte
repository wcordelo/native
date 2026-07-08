<script>
  import { onMount } from "svelte";

  let bridge = $state("checking...");

  onMount(() => {
    bridge = window.zero ? "available" : "not enabled";
  });
</script>

<main>
  <p class="eyebrow">Native SDK + Svelte</p>
  <h1>App</h1>
  <p class="lede">A Svelte frontend running inside the system WebView.</p>
  <div class="card">
    <span>Native bridge</span>
    <strong>{bridge}</strong>
  </div>
</main>
