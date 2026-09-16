import React, { useState, useRef, useEffect, useCallback } from 'react';
import './App.css';
const API_URL  = import.meta.env.VITE_API_URL || 'https://llm-ops.akamai-poc.online';
const MODEL    = import.meta.env.VITE_MODEL   || 'qwen25-7b';
const PROM_URL = (import.meta.env.VITE_API_URL || 'https://llm-ops.akamai-poc.online') + '/prometheus';

const SUGGESTIONS = [
  'How does KV cache autoscaling work?',
  'Explain PagedAttention in vLLM',
  'What triggers KEDA to scale out?',
  'Compare tensor vs pipeline parallelism',
];

function AkamaiLogo() {
  return (
    <img src="/akamai-logo.png" alt="Akamai" style={{ width: 22, height: 22, objectFit: 'contain' }} />
  );
}

function MetricBar({ value, max = 100 }) {
  const pct = Math.min(100, (value / max) * 100);
  const color = pct > 85 ? 'var(--ak-error)' : pct > 65 ? 'var(--ak-warning)' : 'var(--ak-accent)';
  return (
    <div className="metric-bar-wrap">
      <div className="metric-bar" style={{ width: `${pct}%`, background: color }} />
    </div>
  );
}

function TypingIndicator() {
  return (
    <div className="msg ai">
      <div className="avatar ai">A</div>
      <div className="msg-body">
        <div className="typing-bubble">
          <div className="dot" />
          <div className="dot" />
          <div className="dot" />
        </div>
      </div>
    </div>
  );
}

function Message({ msg }) {
  const isUser = msg.role === 'user';
  return (
    <div className={`msg ${msg.role}`}>
      <div className={`avatar ${msg.role}`}>
        {isUser ? <i className="ti ti-user" aria-hidden="true" /> : 'A'}
      </div>
      <div className="msg-body">
        {msg.error ? (
          <div className="error-bubble">
            <i className="ti ti-alert-circle" aria-hidden="true" />
            {msg.content}
          </div>
        ) : (
          <div
            className="bubble"
            dangerouslySetInnerHTML={{ __html: msg.content + (msg.streaming ? '<span class="cursor"></span>' : '') }}
          />
        )}
        {!isUser && !msg.streaming && msg.tokens > 0 && (
          <div className="bubble-meta">
            <span className="token-pill">
              <i className="ti ti-cpu" aria-hidden="true" />
              {msg.tokens} tokens
            </span>
            {msg.ttft && <span className="latency-text">{msg.ttft.toFixed(1)}s TTFT</span>}
            {msg.tps  && <span className="latency-text">· {msg.tps.toFixed(1)} tok/s</span>}
          </div>
        )}
      </div>
    </div>
  );
}

function ConfigPanel({ config, onChange, onClose }) {
  return (
    <div className="config-overlay">
      <div className="config-title">
        Model settings
        <i className="ti ti-x config-close" onClick={onClose} aria-label="Close settings" />
      </div>

      <div className="config-group">
        <div className="config-label">API endpoint</div>
        <input
          className="config-input"
          value={config.apiUrl}
          onChange={e => onChange('apiUrl', e.target.value)}
          placeholder="https://llm-ops.akamai-poc.online"
        />
      </div>

      <div className="config-group">
        <div className="config-label">Model name</div>
        <input
          className="config-input"
          value={config.model}
          onChange={e => onChange('model', e.target.value)}
          placeholder="qwen25-7b"
        />
      </div>

      <div className="config-group">
        <div className="config-label">Max tokens</div>
        <div className="range-row">
          <input
            type="range" min="64" max="4096" step="64"
            value={config.maxTokens}
            onChange={e => onChange('maxTokens', Number(e.target.value))}
          />
          <span className="range-val">{config.maxTokens}</span>
        </div>
      </div>

      <div className="config-group">
        <div className="config-label">Temperature</div>
        <div className="range-row">
          <input
            type="range" min="0" max="2" step="0.05"
            value={config.temperature}
            onChange={e => onChange('temperature', Number(e.target.value))}
          />
          <span className="range-val">{config.temperature.toFixed(2)}</span>
        </div>
      </div>

      <div className="config-group">
        <div className="config-label">System prompt</div>
        <textarea
          className="config-input"
          rows={4}
          style={{ resize: 'vertical', minHeight: 80 }}
          value={config.systemPrompt}
          onChange={e => onChange('systemPrompt', e.target.value)}
          placeholder="Optional system prompt..."
        />
      </div>

      <div className="config-info">
        <strong>Endpoint:</strong> {config.apiUrl}/v1/chat/completions
      </div>
    </div>
  );
}

export default function App() {
  const [messages, setMessages]     = useState([]);
  const [input, setInput]           = useState('');
  const [loading, setLoading]       = useState(false);
  const [streamPct, setStreamPct]   = useState(0);
  const [showConfig, setShowConfig] = useState(false);
  const [metrics, setMetrics]       = useState({ kv: 0, replicas: 0, queue: 0, gpu: 0, loading: true });

  const [config, setConfig] = useState({
    apiUrl:       API_URL,
    model:        MODEL,
    maxTokens:    512,
    temperature:  0.7,
    systemPrompt: '',
  });

  const messagesEndRef = useRef(null);
  const textareaRef    = useRef(null);
  const abortRef       = useRef(null);

  // Scroll to bottom on new messages
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  // Poll Prometheus every 15s for real cluster metrics
  useEffect(() => {
    const queries = {
      kv:       `avg(vllm:kv_cache_usage_perc{model_name="${MODEL}"}) * 100`,
      queue:    `sum(vllm:num_requests_waiting{model_name="${MODEL}"})`,
      gpu:      `avg(DCGM_FI_DEV_GPU_UTIL{exported_namespace="llm-serving"})`,
      replicas: `kube_deployment_status_replicas_ready{deployment="qwen25-7b",namespace="llm-serving"}`,
    };

    const fetchMetric = async (query) => {
      try {
        const res = await fetch(
          `${PROM_URL}/api/v1/query?query=${encodeURIComponent(query)}`
        );
        if (!res.ok) return null;
        const data = await res.json();
        const val = data?.data?.result?.[0]?.value?.[1];
        return val !== undefined ? parseFloat(val) : null;
      } catch {
        return null;
      }
    };

    const poll = async () => {
      const [kv, queue, gpu, replicas] = await Promise.all([
        fetchMetric(queries.kv),
        fetchMetric(queries.queue),
        fetchMetric(queries.gpu),
        fetchMetric(queries.replicas),
      ]);
      setMetrics({
        kv:       kv       !== null ? kv       : 0,
        queue:    queue    !== null ? queue    : 0,
        gpu:      gpu      !== null ? gpu      : 0,
        replicas: replicas !== null ? replicas : 0,
        loading:  false,
      });
    };

    poll();
    const interval = setInterval(poll, 15000);
    return () => clearInterval(interval);
  }, []);

  const updateConfig = useCallback((key, val) => {
    setConfig(prev => ({ ...prev, [key]: val }));
  }, []);

  const handleInput = e => {
    setInput(e.target.value);
    const ta = textareaRef.current;
    if (ta) { ta.style.height = 'auto'; ta.style.height = Math.min(ta.scrollHeight, 140) + 'px'; }
  };

  const sendMessage = useCallback(async (text) => {
    const prompt = text || input.trim();
    if (!prompt || loading) return;
    setInput('');
    if (textareaRef.current) textareaRef.current.style.height = 'auto';

    const userMsg = { id: Date.now(), role: 'user', content: prompt };
    const aiId    = Date.now() + 1;
    const aiMsg   = { id: aiId, role: 'ai', content: '', streaming: true, tokens: 0, ttft: null, tps: null };

    setMessages(prev => [...prev, userMsg, aiMsg]);
    setLoading(true);
    setStreamPct(2);

    const history = messages
      .filter(m => !m.error && !m.streaming)
      .map(m => ({ role: m.role === 'ai' ? 'assistant' : 'user', content: m.content }));

    const body = {
      model: config.model,
      messages: [
        ...(config.systemPrompt ? [{ role: 'system', content: config.systemPrompt }] : []),
        ...history,
        { role: 'user', content: prompt },
      ],
      max_tokens: config.maxTokens,
      temperature: config.temperature,
      stream: true,
    };

    const controller = new AbortController();
    abortRef.current = controller;
    const startTime = Date.now();
    let ttft = null;
    let tokenCount = 0;
    let accumulated = '';
    let animFrame = null;

    const advanceStream = () => {
      setStreamPct(prev => Math.min(prev + Math.random() * 8, 90));
      animFrame = setTimeout(advanceStream, 150);
    };
    advanceStream();

    try {
      const res = await fetch(`${config.apiUrl}/v1/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: controller.signal,
      });

      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const reader = res.body.getReader();
      const decoder = new TextDecoder();

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        const chunk = decoder.decode(value, { stream: true });
        const lines = chunk.split('\n').filter(l => l.trim());

        for (const line of lines) {
          if (!line.startsWith('data:')) continue;
          const data = line.slice(5).trim();
          if (data === '[DONE]') continue;

          try {
            const parsed = JSON.parse(data);
            const delta  = parsed.choices?.[0]?.delta?.content || '';
            if (delta) {
              if (ttft === null) ttft = (Date.now() - startTime) / 1000;
              tokenCount++;
              accumulated += delta;
              setMessages(prev => prev.map(m =>
                m.id === aiId ? { ...m, content: accumulated, tokens: tokenCount } : m
              ));
            }
          } catch {}
        }
      }

      clearTimeout(animFrame);
      const elapsed = (Date.now() - startTime) / 1000;
      const tps = tokenCount / elapsed;

      setMessages(prev => prev.map(m =>
        m.id === aiId
          ? { ...m, streaming: false, tokens: tokenCount, ttft, tps }
          : m
      ));
      setStreamPct(100);
      setTimeout(() => setStreamPct(0), 400);

    } catch (err) {
      clearTimeout(animFrame);
      if (err.name !== 'AbortError') {
        setMessages(prev => prev.map(m =>
          m.id === aiId
            ? { ...m, streaming: false, error: true, content: `Request failed: ${err.message}. Check that ${config.apiUrl} is reachable.` }
            : m
        ));
      }
      setStreamPct(0);
    } finally {
      setLoading(false);
      abortRef.current = null;
    }
  }, [input, loading, messages, config]);

  const handleKeyDown = e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
  };

  const stopGeneration = () => {
    abortRef.current?.abort();
    setMessages(prev => prev.map(m => m.streaming ? { ...m, streaming: false } : m));
    setLoading(false);
    setStreamPct(0);
  };

  const clearChat = () => setMessages([]);

  const kvClass  = metrics.kv  > 85 ? 'bad' : metrics.kv  > 65 ? 'warn' : 'good';
  const gpuClass = metrics.gpu > 90 ? 'bad' : metrics.gpu > 70 ? 'warn' : 'good';

  return (
    <div className="app" style={{ position: 'relative' }}>

      {/* Topbar */}
      <div className="topbar">
        <div className="logo">
          <div className="logo-mark"><AkamaiLogo /></div>
          <span className="logo-text">Akamai <span>LLM</span> Console</span>
        </div>
        <div className="topbar-right">
          <div className="model-badge">
            <div className="status-dot" />
            {config.model} · lke-us-sea
          </div>
          <button className="icon-btn" onClick={() => setShowConfig(v => !v)} title="Settings" aria-label="Open settings">
            <i className="ti ti-settings" aria-hidden="true" />
          </button>
        </div>
      </div>

      {/* Main */}
      <div className="main">

        {/* Sidebar */}
        <div className="sidebar">
          <div className="sidebar-section">
            <button className="new-chat-btn" onClick={clearChat}>
              <i className="ti ti-plus" aria-hidden="true" />
              New chat
            </button>
          </div>

          <div className="sidebar-divider" />

          <div className="sidebar-section">
            <div className="sidebar-label">Tools</div>
            <a
              href="https://grafana-llm.akamai-poc.online"
              target="_blank"
              rel="noopener noreferrer"
              className="sidebar-item"
              style={{ textDecoration: 'none' }}
            >
              <i className="ti ti-chart-bar" aria-hidden="true" />
              Grafana
            </a>
          </div>

          <div className="metrics-panel">
            <div className="metrics-title">
              Cluster metrics
              {metrics.loading && (
                <span style={{ fontSize: 10, color: 'var(--ak-text-dim)', marginLeft: 6 }}>
                  loading...
                </span>
              )}
            </div>

            <div className="metric-row">
              <span className="metric-label">KV cache</span>
              <span className={`metric-value ${kvClass}`}>
                {metrics.loading ? '—' : metrics.kv.toFixed(0) + '%'}
              </span>
            </div>
            <MetricBar value={metrics.kv} />

            <div className="metric-row">
              <span className="metric-label">GPU util</span>
              <span className={`metric-value ${gpuClass}`}>
                {metrics.loading ? '—' : metrics.gpu.toFixed(0) + '%'}
              </span>
            </div>
            <MetricBar value={metrics.gpu} />

            <div className="metric-row">
              <span className="metric-label">Replicas</span>
              <span className="metric-value good">
                {metrics.loading ? '—' : metrics.replicas + ' / 4'}
              </span>
            </div>
            <div className="metric-row">
              <span className="metric-label">Queue depth</span>
              <span className={`metric-value ${metrics.queue > 2 ? 'warn' : 'good'}`}>
                {metrics.loading ? '—' : metrics.queue}
              </span>
            </div>
          </div>
        </div>

        {/* Chat */}
        <div className="chat-area">
          <div className="messages">
            {messages.length === 0 && (
              <div className="empty-state">
                <div className="empty-icon" style={{ width: 80, height: 80, background: 'var(--ak-accent)', borderRadius: 20, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                  <img src="/akamai-logo.png" alt="Akamai" style={{ width: 52, height: 52, objectFit: 'contain' }} />
                </div>
                <div className="empty-title">Akamai LLM Console</div>
                <div className="empty-sub">
                  Ask anything — running on {config.model} via vLLM on LKE,
                  autoscaling with KEDA based on KV cache and queue depth.
                </div>
                <div className="suggestion-chips">
                  {SUGGESTIONS.map(s => (
                    <button key={s} className="chip" onClick={() => sendMessage(s)}>{s}</button>
                  ))}
                </div>
              </div>
            )}

            {messages.map(msg => (
              msg.streaming && msg.content === ''
                ? <TypingIndicator key={msg.id} />
                : <Message key={msg.id} msg={msg} />
            ))}
            <div ref={messagesEndRef} />
          </div>

          {/* Input */}
          <div className="input-area">
            <div className="stream-track">
              <div className="stream-fill" style={{ width: `${streamPct}%` }} />
            </div>

            <div className="params-row">
              <div className="param-chip">
                max_tokens
                <select value={config.maxTokens} onChange={e => updateConfig('maxTokens', Number(e.target.value))}>
                  {[256, 512, 1024, 2048, 4096].map(v => <option key={v} value={v}>{v}</option>)}
                </select>
              </div>
              <div className="param-chip">
                temp
                <select
                  value={config.temperature}
                  onChange={e => updateConfig('temperature', Number(e.target.value))}
                >
                  {[0.0, 0.3, 0.5, 0.7, 1.0].map(v => (
                    <option key={v} value={v}>{v.toFixed(1)}</option>
                  ))}
                </select>
              </div>
              <div className="param-chip">
                model: <span style={{ color: 'var(--ak-accent)', marginLeft: 4 }}>{config.model}</span>
              </div>
            </div>

            <div className="input-row">
              <div className="input-wrap">
                <textarea
                  ref={textareaRef}
                  value={input}
                  onChange={handleInput}
                  onKeyDown={handleKeyDown}
                  placeholder="Ask anything… (Enter to send, Shift+Enter for new line)"
                  rows={1}
                  disabled={loading}
                />
                <div className="input-footer">
                  <span className="char-count">{input.length} / 4096</span>
                </div>
              </div>

              {loading ? (
                <button
                  className="send-btn"
                  onClick={stopGeneration}
                  title="Stop generation"
                  aria-label="Stop generation"
                  style={{ background: 'var(--ak-error)' }}
                >
                  <i className="ti ti-player-stop-filled" aria-hidden="true" />
                </button>
              ) : (
                <button
                  className="send-btn"
                  onClick={() => sendMessage()}
                  disabled={!input.trim()}
                  aria-label="Send"
                >
                  <i className="ti ti-send-2" aria-hidden="true" />
                </button>
              )}
            </div>
          </div>
        </div>
      </div>

      {showConfig && (
        <ConfigPanel config={config} onChange={updateConfig} onClose={() => setShowConfig(false)} />
      )}
    </div>
  );
}