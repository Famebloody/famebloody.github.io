---
layout: default
title: DigneZzZ Script Hub
---

<!-- Tailwind CSS -->
<script src="https://cdn.tailwindcss.com"></script>
<script>
  tailwind.config = {
    darkMode: 'class',
    theme: {
      extend: {
        colors: {
          brand: '#6366f1',
        }
      }
    }
  }
</script>

<!-- Авто-тема -->
<script>
  if (
    localStorage.getItem('theme') === 'dark' ||
    (!('theme' in localStorage) && window.matchMedia('(prefers-color-scheme: dark)').matches)
  ) {
    document.documentElement.classList.add('dark')
  }
</script>

<div class="min-h-screen bg-gradient-to-tr from-gray-50 via-white to-gray-100 dark:from-gray-900 dark:via-gray-800 dark:to-gray-900 text-gray-800 dark:text-gray-100 transition duration-300">
  <!-- Навбар -->
  <header class="flex justify-between items-center px-6 py-4 bg-white dark:bg-gray-900 shadow">
    <div class="text-xl font-semibold">🧠 DigneZzZ</div>
    <div class="flex gap-4 text-sm">
      <a href="https://openode.xyz" class="hover:underline">Forum</a>
      <a href="https://openode.xyz/subscriptions/" class="hover:underline">Clubs</a>
      <a href="https://neonode.cc" class="hover:underline">Blog</a>
      <button id="toggleTheme" class="border px-2 py-1 rounded hover:bg-gray-100 dark:hover:bg-gray-700">🌗 Theme</button>
    </div>
  </header>

  <!-- Контент -->
  <main class="max-w-4xl mx-auto px-4 py-12">
    <div class="text-center mb-10">
      <h1 class="text-4xl font-bold">🧠 DigneZzZ Script Hub</h1>
      <p class="text-gray-600 dark:text-gray-400">A curated collection of scripts, tools, and automation guides.</p>
    </div>

    <div class="grid md:grid-cols-2 gap-6">
      <!-- Карточки -->
      {% assign sections = "Marzban:marzban,Server:server,All Scripts:README.md" | split: "," %}
      {% for section in sections %}
        {% assign label = section | split: ":" | first %}
        {% assign path = section | split: ":" | last %}
        <div class="bg-white dark:bg-gray-800 shadow-xl rounded-lg p-6 relative">
          <h2 class="text-xl font-semibold mb-2">{{ label }}</h2>
          <p class="text-gray-600 dark:text-gray-300 mb-3">
            {% if label == "Marzban" %}
              Scripts for installing, automating, and monitoring Marzban.
            {% elsif label == "Server" %}
              General-purpose scripts: SSH, swap, firewalls, panels, and more.
            {% else %}
              Automatically generated list of all scripts across categories.
            {% endif %}
          </p>
          <button onclick="toggleContent('{{ path | replace: '.', '-' }}', './{{ path }}')" class="text-blue-500 hover:underline text-sm">
            → Show {{ label }} Scripts
          </button>
          <div id="{{ path | replace: '.', '-' }}" class="mt-4 hidden transition-all overflow-hidden text-sm prose dark:prose-invert max-w-none"></div>
        </div>
      {% endfor %}

      <!-- Дополнительно -->
      <div class="bg-white dark:bg-gray-800 shadow-xl rounded-lg p-6">
        <h2 class="text-xl font-semibold mb-2">Resources</h2>
        <ul class="text-blue-400 list-disc list-inside text-sm">
          <li><a href="https://openode.xyz" class="hover:underline">Forum</a></li>
          <li><a href="https://openode.xyz/subscriptions/" class="hover:underline">Clubs: Marzban & Remnawave</a></li>
          <li><a href="https://neonode.cc" class="hover:underline">Blog: neonode.cc</a></li>
        </ul>
      </div>
    </div>
  </main>
</div>

<!-- Markdown parser -->
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>

<!-- Toggle scripts logic -->
<script>
  const toggleTheme = document.getElementById('toggleTheme')
  toggleTheme?.addEventListener('click', () => {
    document.documentElement.classList.toggle('dark')
    localStorage.setItem('theme', document.documentElement.classList.contains('dark') ? 'dark' : 'light')
  })

  async function toggleContent(id, file) {
    const container = document.getElementById(id)
    if (!container) return

    if (container.classList.contains('hidden')) {
      if (!container.innerHTML.trim()) {
        try {
          container.innerHTML = "<p class='text-gray-500'>Loading...</p>"
          const res = await fetch(file)
          const text = await res.text()
          container.innerHTML = marked.parse(text)
        } catch {
          container.innerHTML = "<p class='text-red-500'>Could not load content.</p>"
        }
      }
      container.classList.remove('hidden')
    } else {
      container.classList.add('hidden')
    }
  }
</script>
