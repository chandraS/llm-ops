import React, { useState, useEffect, useCallback } from 'react';

const LOADTEST_BASE = '/api/loadtest';
const TOKEN_KEY = 'loadtest_token';

const MODES = [
  { id: 'queue', label: 'Queue Depth', hint: 'Short prompts fired fast — spikes num_requests_waiting' },
  { id: 'kv', label: 'KV Cache', hint: 'Long prompts, long context — spikes kv_cache_usage_perc' },
  { id: 'combined', label: 'Combined', hint: 'Mixed load — moves every panel at once' },
];

const DURATION_MARKS = [30, 60, 120, 180, 300, 600];

function fmtDuration(s) {
  return s >= 60 && s % 60 === 0 ? `${s / 60}m` : `${s}s`;
}

export default function LoadTestPanel({ onClose }) {
  const [mode, setMode] = useState('combined');
  const [concurrency, setConcurrency] = useState(10);
  const [durationIdx, setDurationIdx] = useState(DURATION_MARKS.indexOf(180));
  const duration = DURATION_MARKS[durationIdx];

  const [status, setStatus] = useState({ status: 'idle' });
  const [stopping, setStopping] = useState(false);
  const [error, setError] = useState('');
  const [needsToken, setNeedsToken] = useState(!localStorage.getItem(TOKEN_KEY));
  const [tokenInput, setTokenInput] = useState('');
  const [showPasscodeForm, setShowPasscodeForm] = useState(false);

  const fetchStatus = useCallback(async () => {
    try {
      const res = await fetch(`${LOADTEST_BASE}/status`);
      if (!res.ok) return;
      const data = await res.json();
      setStatus(data);
      if (data.status === 'idle') setStopping(false);
    } catch {
      // transient — next poll will retry
    }
  }, []);

  useEffect(() => {
    fetchStatus();
    const interval = setInterval(fetchStatus, 2000);
    return () => clearInterval(interval);
  }, [fetchStatus]);

  const authHeader = () => {
    const token = localStorage.getItem(TOKEN_KEY);
    return token ? { 'X-Load-Test-Token': token } : {};
  };

  const doStart = useCallback(async () => {
    setError('');
    try {
      const res = await fetch(`${LOADTEST_BASE}/start`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeader() },
        body: JSON.stringify({ mode, concurrency, duration }),
      });
      if (res.status === 401) {
        localStorage.removeItem(TOKEN_KEY);
        setNeedsToken(true);
        setError('Passcode rejected — try again.');
        return;
      }
      if (res.status === 409) {
        setError('A load test is already running.');
        fetchStatus();
        return;
      }
      if (!res.ok) {
        setError(`Failed to start (HTTP ${res.status}).`);
        return;
      }
      fetchStatus();
    } catch {
      setError('Could not reach the load test service.');
    }
  }, [mode, concurrency, duration, fetchStatus]);

  const handleStartClick = () => {
    if (needsToken) {
      setShowPasscodeForm(true);
      return;
    }
    doStart();
  };

  const handleUnlock = async (e) => {
    e.preventDefault();
    if (!tokenInput.trim()) return;
    localStorage.setItem(TOKEN_KEY, tokenInput.trim());
    setTokenInput('');
    setNeedsToken(false);
    setShowPasscodeForm(false);
    doStart();
  };

  const handleStop = async () => {
    setError('');
    setStopping(true);
    try {
      const res = await fetch(`${LOADTEST_BASE}/stop`, {
        method: 'POST',
        headers: authHeader(),
      });
      if (res.status === 401) {
        localStorage.removeItem(TOKEN_KEY);
        setNeedsToken(true);
        setStopping(false);
        return;
      }
      fetchStatus();
    } catch {
      setError('Could not reach the load test service.');
      setStopping(false);
    }
  };

  const running = status.status === 'running' || stopping;

  return (
    <div className="config-overlay loadtest-overlay">
      <div className="config-title">
        <span><i className="ti ti-bolt" aria-hidden="true" style={{ marginRight: 6 }} />vLLM Load Test</span>
        <i className="ti ti-x config-close" onClick={onClose} aria-label="Close load test panel" />
      </div>

      <div className={`lt-status-pill ${stopping ? 'stopping' : running ? 'running' : 'idle'}`}>
        <span className="lt-status-dot" />
        {stopping ? 'stopping…' : running ? 'running' : 'idle'}
      </div>

      <div className="config-group">
        <div className="config-label">Mode</div>
        <div className="lt-mode-grid">
          {MODES.map(m => (
            <button
              key={m.id}
              className={`lt-mode-btn ${mode === m.id ? 'active' : ''}`}
              onClick={() => setMode(m.id)}
              disabled={running}
            >
              {m.label}
            </button>
          ))}
        </div>
        <div className="lt-hint">{MODES.find(m => m.id === mode)?.hint}</div>
      </div>

      <div className="config-group">
        <div className="config-label">Concurrency <span className="range-val" style={{ display: 'inline' }}>{concurrency}</span></div>
        <div className="range-row">
          <input
            type="range" min="1" max="180" step="1"
            value={concurrency}
            onChange={e => setConcurrency(Number(e.target.value))}
            disabled={running}
          />
        </div>
        <div className="lt-tick-row">
          <span>1</span>
          <span>180</span>
        </div>
      </div>

      <div className="config-group">
        <div className="config-label">Duration <span className="range-val" style={{ display: 'inline' }}>{fmtDuration(duration)}</span></div>
        <div className="range-row">
          <input
            type="range" min="0" max={DURATION_MARKS.length - 1} step="1"
            value={durationIdx}
            onChange={e => setDurationIdx(Number(e.target.value))}
            disabled={running}
          />
        </div>
        <div className="lt-tick-row">
          {DURATION_MARKS.map((s, i) => (
            <span key={s} className={i === durationIdx ? 'active' : ''}>{fmtDuration(s)}</span>
          ))}
        </div>
      </div>

      {needsToken && !showPasscodeForm && (
        <div className="config-info" style={{ marginBottom: 14 }}>
          <i className="ti ti-lock" aria-hidden="true" style={{ marginRight: 6 }} />
          Starting a load test needs the operator passcode — you'll be asked for it.
        </div>
      )}

      {needsToken && showPasscodeForm && (
        <form className="config-group" onSubmit={handleUnlock}>
          <div className="config-label">Operator passcode</div>
          <input
            type="password"
            className="config-input"
            value={tokenInput}
            onChange={e => setTokenInput(e.target.value)}
            placeholder="Enter passcode to run load tests"
            autoFocus
          />
          <button type="submit" className="new-chat-btn" style={{ marginTop: 8, width: '100%' }}>
            Unlock
          </button>
        </form>
      )}

      {error && (
        <div className="config-info" style={{ borderColor: 'var(--ak-error)', color: 'var(--ak-error)', marginBottom: 14 }}>
          {error}
        </div>
      )}

      {running ? (
        <button className="lt-start-btn lt-stop" onClick={handleStop} disabled={stopping}>
          <i className={`ti ${stopping ? 'ti-loader-2' : 'ti-player-stop-filled'}`} aria-hidden="true" />
          {stopping ? 'Stopping…' : 'Stop load test'}
        </button>
      ) : (
        !needsToken || !showPasscodeForm ? (
          <button className="lt-start-btn" onClick={handleStartClick}>
            Start load test
          </button>
        ) : null
      )}

      {(running || status.sent > 0) && (
        <div className="lt-live-stats">
          <div className="metric-row">
            <span className="metric-label">Mode</span>
            <span className="metric-value">{status.mode || mode}</span>
          </div>
          <div className="metric-row">
            <span className="metric-label">Elapsed</span>
            <span className="metric-value">{status.elapsed ?? 0}s</span>
          </div>
          <div className="metric-row">
            <span className="metric-label">Sent / Done / Failed</span>
            <span className="metric-value">{status.sent ?? 0} / {status.completed ?? 0} / {status.failed ?? 0}</span>
          </div>
        </div>
      )}
    </div>
  );
}
