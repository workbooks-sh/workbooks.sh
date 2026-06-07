<script lang="ts">
  import type { PageData } from "./$types";
  import Header from "$lib/components/lander/Header.svelte";
  import Hero from "$lib/components/lander/Hero.svelte";
  import TheaterSection from "$lib/components/lander/TheaterSection.svelte";
  import DataTypesSection from "$lib/components/lander/DataTypesSection.svelte";
  import Footer from "$lib/components/lander/Footer.svelte";

  interface Props { data: PageData & { signedIn?: boolean } }
  let { data }: Props = $props();
</script>

<svelte:head>
  <title>brandnana — brand intelligence for agents</title>
  <meta
    name="description"
    content="One CLI call returns a self-contained brand book — logos, palette, fonts, competitor ads, product catalogs — installed straight into Claude Code."
  />
</svelte:head>

<div class="bg-white min-h-screen flex flex-col text-fg overflow-x-clip">
  <Header signedIn={data?.signedIn ?? false} />
  <Hero />
  <TheaterSection />
  <DataTypesSection />
  <Footer />
</div>
