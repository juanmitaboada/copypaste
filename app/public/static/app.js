'use strict';

// All page behaviour lives here: the CSP forbids inline scripts, so pages pass
// their state through data-* attributes on <body>.

(function () {
  const body = document.body;
  const $ = (sel) => document.querySelector(sel);

  function flash(button, label) {
    const old = button.textContent;
    button.textContent = label;
    setTimeout(() => { button.textContent = old; }, 1200);
  }

  function copyText(text, button, label) {
    const done = () => flash(button, label);
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, () => fallbackCopy(text, done));
    } else {
      fallbackCopy(text, done);
    }
  }

  function fallbackCopy(text, done) {
    // execCommand is deprecated but is the only option on plain-http test setups.
    const tmp = document.createElement('textarea');
    tmp.value = text;
    tmp.setAttribute('readonly', '');
    tmp.style.position = 'absolute';
    tmp.style.left = '-9999px';
    document.body.appendChild(tmp);
    tmp.select();
    const ok = document.execCommand('copy');
    tmp.remove();
    if (ok) done();
  }

  document.querySelectorAll('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const el = $(btn.dataset.copy);
      if (el) copyText(el.value, btn, 'Copied');
    });
  });

  // Share: the note's canonical URL on this site (data-share holds its path).
  document.querySelectorAll('[data-share]').forEach((btn) => {
    btn.addEventListener('click', () => copyText(location.origin + btn.dataset.share, btn, 'Link copied'));
  });

  document.querySelectorAll('form[data-confirm]').forEach((form) => {
    form.addEventListener('submit', (ev) => {
      if (!confirm(form.dataset.confirm)) ev.preventDefault();
    });
  });

  const page = body.dataset.page;
  if (page === 'editor' || page === 'view') initEditor(page === 'editor');
  if (page === 'new') initNew();
  if (page === 'admin') initAdmin();
  // The revealed text arrived via POST ?a=reveal: drop the query so a reload is a
  // plain GET ("not found") instead of a "resend form?" prompt.
  if (page === 'burned') history.replaceState(null, '', location.pathname);

  function initEditor(editable) {
    const textarea = $('#content');
    const statusEl = $('#status');
    const sizeEl = $('#size');
    const conflictEl = $('#conflict');
    const errorEl = $('#error');
    const url = body.dataset.url;
    const max = parseInt(body.dataset.max, 10);
    const encoder = new TextEncoder();
    let base = body.dataset.hash;
    let saved = textarea.value;   // text the server holds as `base`
    let inFlight = false;
    let conflict = false;
    let timer = null;
    let leaving = false;
    const POLL_MS = 3000;
    let pollTimer = null;
    let stopped = false;   // note gone or locked: nothing left to sync

    const setStatus = (text, cls) => {
      statusEl.textContent = text;
      statusEl.className = 'status' + (cls ? ' ' + cls : '');
    };
    const showError = (text) => {
      errorEl.textContent = text;
      errorEl.hidden = !text;
    };
    const updateSize = () => {
      const bytes = encoder.encode(textarea.value).length;
      const used = bytes < 1024 ? bytes + ' B' : (bytes / 1024).toFixed(1) + ' KB';
      sizeEl.textContent = used + ' of ' + Math.round(max / 1024) + ' KB';
      sizeEl.classList.toggle('error', bytes > max);
      return bytes;
    };

    function schedule(delay) {
      clearTimeout(timer);
      timer = setTimeout(save, delay);
    }

    async function save() {
      if (conflict || inFlight || textarea.value === saved) return;
      if (updateSize() > max) {
        setStatus('Too large, not saved', 'error');
        return;
      }
      inFlight = true;
      const text = textarea.value;
      let retryIn = 0; // 0 = only resave if the user keeps typing
      setStatus('Saving…');
      try {
        const res = await fetch(url + '?a=save', {
          method: 'POST',
          headers: { 'Content-Type': 'text/plain;charset=UTF-8', 'X-CP-Base': base },
          body: text,
          credentials: 'same-origin',
        });
        const data = await res.json().catch(() => ({}));
        if (res.ok) {
          base = data.hash;
          saved = text;
          showError('');
          retryIn = 800; // catch keystrokes typed while this request was in flight
          setStatus(textarea.value === saved ? 'Saved' : 'Saving…', textarea.value === saved ? 'ok' : '');
        } else if (res.status === 409) {
          // Stop autosaving: retrying would loop forever against the newer server copy.
          conflict = true;
          conflictEl.hidden = false;
          setStatus('Not saved', 'error');
        } else if (res.status === 404 || res.status === 403) {
          conflict = true;
          showError(res.status === 404
            ? 'This note no longer exists on the server. Copy your text if you need it.'
            : 'You can no longer edit this note. Copy your text and reload.');
          setStatus('Not saved', 'error');
        } else if (res.status === 413) {
          setStatus('Too large, not saved', 'error');
        } else {
          showError('Save failed (' + res.status + '). Retrying…');
          setStatus('Not saved', 'error');
          retryIn = 3000;
        }
      } catch (e) {
        setStatus('Offline, retrying…', 'error');
        retryIn = 3000;
      } finally {
        inFlight = false;
        if (!conflict && retryIn && textarea.value !== saved) schedule(retryIn);
      }
    }

    function stopSync(message) {
      stopped = true;
      conflict = true;
      clearTimeout(timer);
      clearTimeout(pollTimer);
      showError(message);
      setStatus(editable ? 'Not saved' : 'Not updating', 'error');
    }

    function schedulePoll(delay) {
      clearTimeout(pollTimer);
      // Hidden tabs do not poll; visibilitychange resumes them immediately.
      if (!stopped && !document.hidden) pollTimer = setTimeout(poll, delay);
    }

    async function poll() {
      if (stopped || conflict) return; // conflict: the server copy is already known to differ
      if (inFlight) {
        schedulePoll(POLL_MS);
        return;
      }
      const sentBase = base;
      try {
        const res = await fetch(url + '?a=poll', {
          headers: { 'X-CP-Base': sentBase },
          credentials: 'same-origin',
          cache: 'no-store',
        });
        if (res.status === 200) {
          const data = await res.json();
          // A save of ours may have landed meanwhile; then this answer is stale.
          if (base === sentBase && !inFlight && data.hash !== base) applyRemote(data.hash, data.content);
        } else if (res.status === 404) {
          stopSync('This note was deleted or has expired. Copy your text if you need it.');
          return;
        } else if (res.status === 403) {
          stopSync('This note is now protected. Copy your text if you need it, then reload.');
          return;
        }
      } catch (e) {
        // Offline or server hiccup: try again on the next tick.
      }
      schedulePoll(POLL_MS);
    }

    function applyRemote(hash, content) {
      if (textarea.value !== saved) {
        // Unsaved local edits against a newer server copy: same situation as a 409.
        conflict = true;
        clearTimeout(timer);
        conflictEl.hidden = false;
        setStatus('Not saved', 'error');
        return;
      }
      const old = textarea.value;
      const { selectionStart, selectionEnd, scrollTop } = textarea;
      // Locate the changed span via common prefix/suffix, then move the caret
      // with the text around it instead of keeping its absolute index.
      let pre = 0;
      const minLen = Math.min(old.length, content.length);
      while (pre < minLen && old[pre] === content[pre]) pre++;
      let suf = 0;
      while (suf < minLen - pre && old[old.length - 1 - suf] === content[content.length - 1 - suf]) suf++;
      const shift = (pos) => {
        // Checked first so a caret exactly at an insertion point (typically the
        // end, when someone appends) ends up after the inserted text.
        if (pos >= old.length - suf) return pos + content.length - old.length; // after the change
        if (pos <= pre) return pos;                                   // before it
        return content.length - suf;                                  // inside: end of new span
      };
      textarea.value = content;
      textarea.setSelectionRange(shift(selectionStart), shift(selectionEnd));
      textarea.scrollTop = scrollTop;
      base = hash;
      saved = content;
      updateSize();
      setStatus('Updated', 'ok');
    }

    document.addEventListener('visibilitychange', () => {
      if (document.hidden) clearTimeout(pollTimer);
      else schedulePoll(0);
    });

    if (editable) {
      textarea.addEventListener('input', () => {
        updateSize();
        if (!conflict) {
          setStatus('Editing…');
          schedule(800);
        }
      });
    }

    $('#reload').addEventListener('click', () => {
      leaving = true;
      location.reload();
    });

    const deleteBtn = $('#delete');
    if (deleteBtn) deleteBtn.addEventListener('click', async () => {
      if (!confirm('Delete this note for everyone?')) return;
      clearTimeout(timer);
      conflict = true; // freeze autosave
      const res = await fetch(url + '?a=delete', { method: 'POST', credentials: 'same-origin' });
      if (res.ok || res.status === 404) {
        leaving = true;
        location.href = '/';
      } else {
        conflict = false;
        showError('Delete failed (' + res.status + ').');
        schedulePoll(POLL_MS);
      }
    });

    window.addEventListener('beforeunload', (ev) => {
      if (!leaving && textarea.value !== saved) {
        ev.preventDefault();
        ev.returnValue = '';
      }
    });

    updateSize();
    setStatus(editable ? 'Saved' : 'Read-only', editable ? 'ok' : '');
    schedulePoll(POLL_MS);
  }

  function initNew() {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    const code = $('#code');
    $('#random').addEventListener('click', () => {
      const bytes = new Uint32Array(7);
      crypto.getRandomValues(bytes);
      code.value = Array.from(bytes, (b) => alphabet[b % alphabet.length]).join('');
    });
    // Follow the zone's default expiry until the user picks one explicitly.
    const expiry = $('#expiry');
    let touched = false;
    expiry.addEventListener('change', () => { touched = true; });
    document.querySelectorAll('input[name="zone"]').forEach((r) => {
      r.addEventListener('change', () => {
        if (!touched) expiry.value = r.value === 'private' ? 'never' : 'idle7d';
      });
    });
  }

  function initAdmin() {
    const action = $('#password_action');
    const pw = $('#password');
    if (action && pw) {
      const sync = () => { pw.hidden = action.value !== 'set'; };
      action.addEventListener('change', sync);
      sync();
    }
  }
})();
