---
layout: default
title: DigneZzZ Scripts Hub
---

<link rel="stylesheet" href="https://unpkg.com/simpledotcss/simple.min.css">

<header>
  <h1>🧠 dignezzz.github.io</h1>
  <p>Твоя личная библиотека скриптов и гайдов — чисто, понятно и по делу.</p>

  <div class="language-switcher" style="margin-top: 1em;">
      <button id="ru" class="active">🇷🇺 Русский</button>
      <button id="en">🇬🇧 English</button>
  </div>
</header>

<main>
  <!-- Категория: Marzban -->
  <section class="lang ru">
    <h2>⚙️ Marzban</h2>
    <p>Скрипты по установке, автоматизации и мониторингу Marzban.</p>
    {% include_relative categories/readme.md %}
  </section>
  <section class="lang en" style="display:none;">
    <h2>⚙️ Marzban</h2>
    <p>Scripts for Marzban installation, automation, and monitoring.</p>
    {% include_relative categories/readme.md %}
  </section>

  <!-- Категория: Сервер -->
  <section class="lang ru">
    <h2>🖥️ Сервер</h2>
    <p>Общие серверные скрипты: SSH, swap, fail2ban, панели управления.</p>
    {% include_relative categories/readme.md %}
  </section>
  <section class="lang en" style="display:none;">
    <h2>🖥️ Server</h2>
    <p>General server scripts: SSH, swap, fail2ban, control panels.</p>
    {% include_relative categories/readme.md %}
  </section>

  <!-- Форум и подписки -->
  <hr>
  <section class="lang ru">
    <p>🔗 Мой форум: <a href="https://openode.xyz">openode.xyz</a> | <a href="https://openode.xyz/subscriptions/">Подписки</a></p>
  </section>
  <section class="lang en" style="display:none;">
    <p>🔗 My forum: <a href="https://openode.xyz">openode.xyz</a> | <a href="https://openode.xyz/subscriptions/">Subscriptions</a></p>
  </section>
</main>

<script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
<script>
  $(function() {
    $('.language-switcher button').click(function() {
      const lang = $(this).attr('id');
      $('.lang').hide();
      $('.' + lang).show();
      $('.language-switcher button').removeClass('active');
      $(this).addClass('active');
    });
  });
</script>
