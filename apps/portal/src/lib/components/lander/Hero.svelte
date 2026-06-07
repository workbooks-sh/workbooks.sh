<script lang="ts">
  import Composer from "../ds/Composer.svelte";
  import InstallBar from "./InstallBar.svelte";
</script>

<section class="bg-white">
  <div class="max-w-6xl mx-auto px-6 md:px-8 pt-20 pb-14 md:pt-28 md:pb-18">
    <div class="max-w-3xl mx-auto text-center">
      <h1 class="font-serif text-[44px] md:text-[68px] leading-[1.04] tracking-[-0.025em] text-fg mb-5">
        Build a brand book your agent can actually read.
      </h1>

      <p class="text-[17px] md:text-[19px] leading-relaxed text-fg-soft mb-9 max-w-2xl mx-auto">
        One call returns a self-contained <strong class="font-semibold text-fg">.html</strong>
        — live logos, palette, fonts, competitor ads, and a deep product catalog —
        installed straight into your agent as a skill.
      </p>

      <div class="flex justify-center">
        <Composer />
      </div>
    </div>
  </div>

  <InstallBar />
</section>
