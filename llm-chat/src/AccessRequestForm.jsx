import React, { useState } from 'react';

export default function AccessRequestForm({ onClose }) {
  const [email, setEmail]           = useState('');
  const [description, setDescription] = useState('');
  const [status, setStatus]         = useState('idle'); // idle | loading | success | error
  const [errorMsg, setErrorMsg]     = useState('');

  const submit = async (e) => {
    e.preventDefault();
    setStatus('loading');
    setErrorMsg('');
    try {
      const res = await fetch('/api/access-request', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, description }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || 'Submission failed');
      setStatus('success');
    } catch (err) {
      setErrorMsg(err.message);
      setStatus('error');
    }
  };

  return (
    <div className="config-overlay">
      <div className="config-title">
        Request load test access
        <i className="ti ti-x config-close" onClick={onClose} aria-label="Close" />
      </div>

      {status === 'success' ? (
        <div style={{ padding: '16px 0', color: 'var(--ak-accent)', fontSize: 14 }}>
          <i className="ti ti-circle-check" style={{ marginRight: 8 }} />
          Request submitted — we'll reach out to <strong>{email}</strong> with an access code.
        </div>
      ) : (
        <form onSubmit={submit}>
          <div className="config-group">
            <div className="config-label">Email</div>
            <input
              className="config-input"
              type="email"
              required
              placeholder="you@example.com"
              value={email}
              onChange={e => setEmail(e.target.value)}
              disabled={status === 'loading'}
            />
          </div>

          <div className="config-group">
            <div className="config-label">How did you find this repo?</div>
            <textarea
              className="config-input"
              required
              minLength={10}
              maxLength={1000}
              rows={5}
              style={{ resize: 'vertical', minHeight: 100 }}
              placeholder="e.g. Found it via a blog post / conference talk / GitHub search..."
              value={description}
              onChange={e => setDescription(e.target.value)}
              disabled={status === 'loading'}
            />
            <div style={{ fontSize: 11, color: 'var(--ak-text-dim)', marginTop: 4 }}>
              {description.length} / 1000
            </div>
          </div>

          {status === 'error' && (
            <div style={{ color: 'var(--ak-error)', fontSize: 13, marginBottom: 12 }}>
              <i className="ti ti-alert-circle" style={{ marginRight: 6 }} />
              {errorMsg}
            </div>
          )}

          <button
            type="submit"
            className="send-btn"
            disabled={status === 'loading' || !email || description.length < 10}
            style={{ width: '100%', borderRadius: 8, justifyContent: 'center', gap: 8 }}
          >
            {status === 'loading'
              ? <><i className="ti ti-loader-2" style={{ animation: 'spin 1s linear infinite' }} /> Submitting…</>
              : <><i className="ti ti-send-2" /> Submit request</>
            }
          </button>
        </form>
      )}
    </div>
  );
}
