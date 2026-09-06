(function () {
  'use strict';
  var script = document.currentScript;
  var endpoint = script && script.getAttribute('data-config-url');
  if (!endpoint || !/^https:\/\//.test(endpoint) || window.__crispaiWelcomeBound) return;
  window.__crispaiWelcomeBound = true;
  window.$crisp = window.$crisp || [];
  var session = '';
  var lastSignal = {};
  var loadGeneration = 0;
  async function currentConfig() {
    if (!session) return null;
    try {
      var url = new URL(endpoint);
      url.searchParams.set('website_id', String(window.CRISP_WEBSITE_ID || ''));
      url.searchParams.set('session_id', session);
      var controller = new AbortController();
      var timer = setTimeout(function () { controller.abort(); }, 3000);
      var response;
      try { response = await fetch(url.href, { cache: 'no-store', credentials: 'omit', redirect: 'error', signal: controller.signal }); } finally { clearTimeout(timer); }
      return response.ok ? await response.json() : null;
    } catch (_) { return null; }
  }
  async function signal(type) {
    var config = await currentConfig();
    if (!config || !config.enabled || !config.welcome_enabled || config.trigger !== type) return;
    var identity = session + ':' + type;
    if (lastSignal[identity] && Date.now() - lastSignal[identity] < 60000) return;
    lastSignal[identity] = Date.now();
    window.$crisp.push(['set', 'session:event', [[['crispai_' + type, { source: 'ai-support' }, 'blue']]]]);
  }
  window.$crisp.push(['on', 'session:loaded', async function (sessionId) {
    session = String(sessionId || '');
    var generation = ++loadGeneration;
    var config = await currentConfig();
    if (generation !== loadGeneration || !config || !config.enabled) return;
    if (config.auto_open === true) window.$crisp.push(['do', 'chat:open']);
    await signal('widget_load');
  }]);
  window.$crisp.push(['on', 'chat:opened', function () { signal('chat_open'); }]);
})();
