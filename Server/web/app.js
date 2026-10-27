(() => {
  const $ = (id) => document.getElementById(id);
  const authView = $('auth-view');
  const dashboard = $('dashboard-view');
  const authForm = $('auth-form');
  const sessionKey = 'kies-drive.web-session';
  let session = sessionStorage.getItem(sessionKey) || '';
  let registerMode = false;
  let refreshTimer;
  let toastTimer;
  let connectionWarningShown = false;

  function message(text, success = false) {
    const node = $('auth-message');
    node.textContent = text;
    node.classList.toggle('success', success);
    node.classList.remove('hidden');
  }

  function toast(text) {
    const node = $('toast');
    node.textContent = text;
    node.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => node.classList.add('hidden'), 4600);
  }

  async function api(path, options = {}) {
    const headers = new Headers(options.headers || {});
    if (session) headers.set('Authorization', `Bearer ${session}`);
    if (options.body) headers.set('Content-Type', 'application/json');
    const response = await fetch(path, { ...options, headers, cache: 'no-store' });
    let body = {};
    try { body = await response.json(); } catch (_) { /* handled below */ }
    if (response.status === 401 && session) {
      clearSession();
      throw new Error('Deine Anmeldung ist abgelaufen. Bitte melde dich erneut an.');
    }
    if (!response.ok) throw new Error(body.detail || body.message || 'Das hat gerade nicht geklappt.');
    return body;
  }

  function clearSession() {
    session = '';
    sessionStorage.removeItem(sessionKey);
    clearInterval(refreshTimer);
    dashboard.classList.add('hidden');
    authView.classList.remove('hidden');
  }

  function showDashboard(email) {
    authView.classList.add('hidden');
    dashboard.classList.remove('hidden');
    $('account-email').textContent = email || '';
    renderOffline();
    refresh();
    clearInterval(refreshTimer);
    refreshTimer = setInterval(refresh, 10000);
  }

  function renderOffline() {
    $('sync-dot').className = 'sync-dot';
    $('sync-label').textContent = 'Warte auf iPhone';
    $('speed').textContent = '—';
    $('heading').textContent = '—';
    $('location').textContent = '—';
    $('updated').textContent = 'Noch keine Live-Daten';
    $('road-status').textContent = 'Kies Drive verbinden';
    $('maneuver-card').classList.add('hidden');
  }

  function setText(id, value, fallback = '—') {
    $(id).textContent = value === null || value === undefined || value === '' ? fallback : value;
  }

  function renderState(state) {
    const live = state.live === true;
    $('sync-dot').className = `sync-dot ${live ? 'live' : 'stale'}`;
    $('sync-label').textContent = live ? 'iPhone verbunden' : 'Keine aktuellen Fahrdaten';
    setText('speed', live && Number.isFinite(state.speed_kmh) ? Math.round(state.speed_kmh) : null);
    setText('heading', live && state.heading ? state.heading.direction : null);
    const location = live ? state.location : null;
    setText('location', location && Number.isFinite(location.latitude) && Number.isFinite(location.longitude)
      ? `${location.latitude.toFixed(5)}, ${location.longitude.toFixed(5)}` : null);
    if (live && Number.isFinite(state.age_seconds)) {
      setText('updated', state.age_seconds < 5 ? 'Gerade aktualisiert' : `Vor ${Math.floor(state.age_seconds)} Sek. aktualisiert`);
    } else {
      setText('updated', state.recorded_at ? `Letztes Signal ${new Date(state.recorded_at).toLocaleString('de-DE')}` : null, 'Noch keine Synchronisierung');
    }
    $('road-status').textContent = live
      ? state.rerouting ? 'Route wird angepasst' : state.on_route === false ? 'Route wird geprüft' : state.navigation_active ? 'Auf deiner Route' : 'Kies Drive ist bereit'
      : 'App öffnen, um zu verbinden';

    const route = state.active_route;
    const lock = state.route_lock;
    $('route-title').textContent = lock?.title || route?.destination || 'Keine aktive Route';
    const badge = $('route-badge');
    badge.textContent = state.navigation_active ? 'NAVIGATION AKTIV' : lock?.status === 'active' ? 'REISE GESPEICHERT' : 'BEREIT';
    badge.className = `badge ${state.navigation_active ? 'active' : lock?.status === 'active' ? 'warning' : ''}`;
    if (route) {
      const kilometres = Number.isFinite(route.distance_metres) ? `${Math.round(route.distance_metres / 1000)} km` : '';
      const minutes = Number.isFinite(route.travel_time_seconds) ? `${Math.round(route.travel_time_seconds / 60)} Min.` : '';
      $('route-summary').textContent = [route.destination, kilometres, minutes].filter(Boolean).join(' · ') || 'Deine Route ist gespeichert.';
    } else if (lock) {
      $('route-summary').textContent = `Ziel: ${lock.destinationName || 'Gespeicherte Reise'} · Die Route wird auf dem iPhone fortgesetzt.`;
    } else {
      $('route-summary').textContent = 'Starte oder stelle deine Reise in der Kies-Drive-App wieder her.';
    }
    $('restore-route').disabled = !lock || lock.status !== 'active';

    const maneuver = live ? state.next_maneuver : null;
    if (maneuver?.instruction) {
      $('maneuver-card').classList.remove('hidden');
      $('maneuver-text').textContent = maneuver.instruction;
      const distance = Number.isFinite(maneuver.distance_metres) ? `${Math.round(maneuver.distance_metres)} m` : '';
      setText('maneuver-distance', distance, '');
    } else {
      $('maneuver-card').classList.add('hidden');
    }

    const list = $('waypoints');
    list.replaceChildren();
    if (lock?.waypoints?.length) {
      const visited = new Set(lock.visitedWaypointIDs || lock.visited_waypoint_ids || []);
      lock.waypoints.forEach((point, index) => {
        const row = document.createElement('div');
        row.className = 'waypoint';
        const name = document.createElement('span');
        name.textContent = point.name || `Pflichtpunkt ${index + 1}`;
        const status = document.createElement('small');
        status.textContent = visited.has(point.id) ? 'Erledigt' : 'Pflichtpunkt';
        row.append(name, status);
        list.append(row);
      });
    }
  }

  async function refresh() {
    if (!session) return;
    try {
      const state = await api('/api/web/state');
      connectionWarningShown = false;
      renderState(state);
    } catch (error) {
      if (session && !connectionWarningShown) {
        connectionWarningShown = true;
        toast(error.message);
      }
    }
  }

  async function sendCommand(command, argumentsValue) {
    try {
      const accepted = await api('/api/web/commands', {
        method: 'POST', body: JSON.stringify({ command, arguments: argumentsValue }),
      });
      toast('An Kies Drive gesendet. Warte auf die Bestätigung vom iPhone …');
      const started = Date.now();
      const check = async () => {
        try {
          const status = await api(`/api/web/commands/${accepted.command_id}`);
          if (status.status === 'done') {
            toast(status.result?.message || 'Kies Drive hat die Aktion übernommen.');
            refresh();
            return true;
          }
          if (['failed', 'expired', 'superseded'].includes(status.status)) {
            toast(status.result?.message || 'Die Aktion wurde nicht ausgeführt. Öffne Kies Drive auf deinem iPhone.');
            return true;
          }
        } catch (error) { toast(error.message); return true; }
        return Date.now() - started > 90000;
      };
      const poll = async () => { if (await check()) clearInterval(timer); };
      const timer = setInterval(poll, 2500);
      poll();
    } catch (error) { toast(error.message); }
  }

  $('auth-switch').addEventListener('click', () => {
    registerMode = !registerMode;
    $('auth-title').textContent = registerMode ? 'Schön, dass du da bist.' : 'Willkommen zurück.';
    $('auth-description').textContent = registerMode ? 'Erstelle dein Kies-Drive-Konto. Wir schicken dir einen Bestätigungslink.' : 'Melde dich mit deinem Kies-Drive-Konto an.';
    authForm.querySelector('button[type="submit"]').innerHTML = registerMode ? 'Konto erstellen <span aria-hidden="true">→</span>' : 'Anmelden <span aria-hidden="true">→</span>';
    $('auth-switch').textContent = registerMode ? 'Schon ein Konto? Anmelden' : 'Neu bei Kies Drive? Konto erstellen';
    $('password').setAttribute('autocomplete', registerMode ? 'new-password' : 'current-password');
    $('totp-field').classList.toggle('hidden', registerMode);
    $('auth-message').classList.add('hidden');
  });

  authForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const email = $('email').value.trim();
    const password = $('password').value;
    $('auth-message').classList.add('hidden');
    try {
      if (registerMode) {
        await api('/auth/register', { method: 'POST', body: JSON.stringify({ email, password }) });
        message('Falls die Registrierung möglich ist, erhältst du eine E-Mail. Bitte bestätige deine Adresse und melde dich danach an.', true);
        return;
      }
      const payload = { email, password };
      if ($('totp').value.trim()) payload.totp_code = $('totp').value.trim();
      const result = await api('/auth/login', { method: 'POST', body: JSON.stringify(payload) });
      session = result.session;
      sessionStorage.setItem(sessionKey, session);
      $('totp').value = '';
      showDashboard(result.email);
    } catch (error) {
      if (error.message.includes('Zwei-Faktor-Code erforderlich')) $('totp-field').classList.remove('hidden');
      message(error.message);
    }
  });

  $('logout').addEventListener('click', async () => {
    try { await api('/auth/logout', { method: 'POST' }); } catch (_) { /* clear locally regardless */ }
    clearSession();
  });
  $('refresh').addEventListener('click', refresh);
  $('restore-route').addEventListener('click', () => sendCommand('restore_route', {}));
  $('destination-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const query = $('destination').value.trim();
    if (query.length >= 2) sendCommand('set_destination', { query });
    event.currentTarget.reset();
  });
  $('stop-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const query = $('stop-query').value.trim();
    if (query.length >= 2) sendCommand('add_route_stop', { query });
    event.currentTarget.reset();
  });

  if (session) {
    api('/auth/me').then((user) => showDashboard(user.email)).catch(() => clearSession());
  }
})();
