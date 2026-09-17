'use strict';

const { describe, test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

// lineage_flow.js is a classic browser script whose only load-time statement
// registers the widget, so a stub HTMLWidgets is all it needs to load in Node
let widgetDef = null;
globalThis.HTMLWidgets = { widget(def) { widgetDef = def; } };
const lf = require(path.join(__dirname, '..', '..', 'inst', 'htmlwidgets', 'lineage_flow.js'));

const NUL = String.fromCharCode(0);
const key = (nodeId, handle) => nodeId + NUL + handle;

function near(actual, expected) {
  assert.ok(Math.abs(actual - expected) < 1e-9, actual + ' is not near ' + expected);
}

// Sets browser globals for the duration of fn (sync or async), then puts
// back whatever was there before
async function withGlobals(overrides, fn) {
  const saved = {};
  for (const name of Object.keys(overrides)) {
    saved[name] = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, {
      value: overrides[name], configurable: true, writable: true
    });
  }
  try {
    return await fn();
  } finally {
    for (const name of Object.keys(overrides)) {
      if (saved[name]) {
        Object.defineProperty(globalThis, name, saved[name]);
      } else {
        delete globalThis[name];
      }
    }
  }
}

const fakeReact = {
  createElement(type, props, ...children) {
    return { type, props, children };
  }
};

function edge(id, source, sourceHandle, target, targetHandle, extra) {
  return Object.assign({ id, source, sourceHandle, target, targetHandle }, extra);
}

describe('computeLaneFractions', () => {
  test('a single target column takes the middle lane', () => {
    const nodes = [{ id: 't', data: { columns: ['a'] } }];
    const fractions = lf.computeLaneFractions(nodes, [edge('e1', 's', 'x', 't', 'a')]);
    assert.deepEqual(Object.keys(fractions), [key('t', 'a')]);
    near(fractions[key('t', 'a')], 0.5);
  });

  test('top rows take the lanes nearest the target, whatever the edge order', () => {
    const nodes = [{ id: 't', data: { columns: ['a', 'b', 'c'] } }];
    const edges = [
      edge('e1', 's', 'x', 't', 'c'),
      edge('e2', 's', 'y', 't', 'a'),
      edge('e3', 's', 'z', 't', 'b')
    ];
    const fractions = lf.computeLaneFractions(nodes, edges);
    near(fractions[key('t', 'a')], 0.2 + 0.6 * 3 / 4);
    near(fractions[key('t', 'b')], 0.2 + 0.6 * 2 / 4);
    near(fractions[key('t', 'c')], 0.2 + 0.6 * 1 / 4);
    Object.values(fractions).forEach((f) => assert.ok(f > 0.2 && f < 0.8));
  });

  test('edges into the same target column share one lane', () => {
    const nodes = [{ id: 't', data: { columns: ['a'] } }];
    const edges = [edge('e1', 's1', 'x', 't', 'a'), edge('e2', 's2', 'y', 't', 'a')];
    assert.deepEqual(Object.keys(lf.computeLaneFractions(nodes, edges)), [key('t', 'a')]);
  });

  test('handles missing from the declared columns sort last', () => {
    const nodes = [{ id: 't', data: { columns: ['a'] } }];
    const edges = [edge('e1', 's', 'x', 't', 'zz'), edge('e2', 's', 'y', 't', 'a')];
    const fractions = lf.computeLaneFractions(nodes, edges);
    assert.ok(fractions[key('t', 'a')] > fractions[key('t', 'zz')]);
  });

  test('a scalar columns value, as jsonlite unboxes it, is treated as one column', () => {
    const nodes = [{ id: 't', data: { columns: 'a' } }];
    const edges = [edge('e1', 's', 'x', 't', 'zz'), edge('e2', 's', 'y', 't', 'a')];
    const fractions = lf.computeLaneFractions(nodes, edges);
    assert.ok(fractions[key('t', 'a')] > fractions[key('t', 'zz')]);
  });

  test('targets without node data or without a node still get lanes', () => {
    const fractions = lf.computeLaneFractions(
      [{ id: 't' }],
      [edge('e1', 's', 'x', 't', 'a'), edge('e2', 's', 'x', 'ghost', 'b')]
    );
    near(fractions[key('t', 'a')], 0.5);
    near(fractions[key('ghost', 'b')], 0.5);
  });

  test('no edges means no lanes', () => {
    assert.deepEqual(lf.computeLaneFractions([{ id: 't', data: { columns: ['a'] } }], []), {});
  });
});

describe('buildAdjacency', () => {
  test('indexes every edge in both directions and keeps its id', () => {
    const adjacency = lf.buildAdjacency([
      edge('e1', 's', 'x', 't', 'a'),
      edge('e2', 's', 'x', 't', 'b'),
      edge('e3', 's', 'y', 't', 'a')
    ]);
    assert.deepEqual(adjacency.out[key('s', 'x')], [
      { key: key('t', 'a'), edgeId: 'e1' },
      { key: key('t', 'b'), edgeId: 'e2' }
    ]);
    assert.deepEqual(adjacency.inn[key('t', 'a')], [
      { key: key('s', 'x'), edgeId: 'e1' },
      { key: key('s', 'y'), edgeId: 'e3' }
    ]);
    assert.equal(adjacency.out[key('t', 'a')], undefined);
  });
});

describe('computeCone', () => {
  const edges = [
    edge('e1', 'A', 'a', 'B', 'b'),
    edge('e2', 'B', 'b', 'C', 'c'),
    // joins two cone members but bypasses the anchor
    edge('e3', 'A', 'a', 'C', 'c'),
    // another parent of C, unrelated to B
    edge('e4', 'X', 'x', 'C', 'c'),
    // a different column of B
    edge('e5', 'B', 'other', 'C', 'c2')
  ];

  test('collects the upstream and downstream columns of the anchor', () => {
    const cone = lf.computeCone(lf.buildAdjacency(edges), { nodeId: 'B', handleId: 'b' });
    assert.deepEqual(
      Object.keys(cone.columnKeys).sort(),
      [key('A', 'a'), key('B', 'b'), key('C', 'c')].sort()
    );
    assert.deepEqual(Object.keys(cone.nodeIds).sort(), ['A', 'B', 'C']);
  });

  test('only traversed edges join the cone', () => {
    const cone = lf.computeCone(lf.buildAdjacency(edges), { nodeId: 'B', handleId: 'b' });
    assert.deepEqual(Object.keys(cone.edgeIds).sort(), ['e1', 'e2']);
  });

  test('walks more than one hop each way', () => {
    const chain = [
      edge('e1', 'A', 'a', 'B', 'b'),
      edge('e2', 'B', 'b', 'C', 'c'),
      edge('e3', 'C', 'c', 'D', 'd'),
      edge('e4', 'D', 'd', 'E', 'e')
    ];
    const cone = lf.computeCone(lf.buildAdjacency(chain), { nodeId: 'C', handleId: 'c' });
    assert.deepEqual(Object.keys(cone.nodeIds).sort(), ['A', 'B', 'C', 'D', 'E']);
    assert.deepEqual(Object.keys(cone.edgeIds).sort(), ['e1', 'e2', 'e3', 'e4']);
  });

  test('terminates on a cycle', () => {
    const cycle = [edge('e1', 'A', 'a', 'B', 'b'), edge('e2', 'B', 'b', 'A', 'a')];
    const cone = lf.computeCone(lf.buildAdjacency(cycle), { nodeId: 'A', handleId: 'a' });
    assert.deepEqual(Object.keys(cone.columnKeys).sort(), [key('A', 'a'), key('B', 'b')].sort());
    assert.deepEqual(Object.keys(cone.edgeIds).sort(), ['e1', 'e2']);
  });

  test('an unconnected column is a cone of one', () => {
    const cone = lf.computeCone(lf.buildAdjacency(edges), { nodeId: 'Z', handleId: 'z' });
    assert.deepEqual(Object.keys(cone.columnKeys), [key('Z', 'z')]);
    assert.deepEqual(cone.edgeIds, {});
    assert.deepEqual(cone.nodeIds, { Z: true });
  });
});

describe('theming', () => {
  const lightColors = { bg: '#f0f7ff', border: '#3b82f6', header: '#1d4ed8', custom: 'kept' };

  test('light theme hands back the payload colors untouched', () => {
    const node = { data: { tableType: 'source', colors: lightColors } };
    assert.equal(lf.themeNodeColors(node, 'light'), lightColors);
    assert.deepEqual(lf.themeNodeColors({}, 'light'), {});
  });

  test('dark theme remaps known table types and keeps other keys', () => {
    const node = { data: { tableType: 'transform', colors: lightColors } };
    const before = structuredClone(lightColors);
    const colors = lf.themeNodeColors(node, 'dark');
    assert.equal(colors.bg, lf.DARK_NODE_PALETTES.transform.bg);
    assert.equal(colors.border, lf.DARK_NODE_PALETTES.transform.border);
    assert.equal(colors.header, lf.DARK_NODE_PALETTES.transform.header);
    assert.equal(colors.nodeBg, lf.THEME_COLORS.dark.nodeBg);
    assert.equal(colors.text, lf.THEME_COLORS.dark.text);
    assert.equal(colors.custom, 'kept');
    assert.deepEqual(lightColors, before);
  });

  test('dark theme leaves an unknown table type on its light colors', () => {
    const node = { data: { tableType: 'staging', colors: lightColors } };
    assert.equal(lf.themeNodeColors(node, 'dark'), lightColors);
  });

  test('darkEdgeColor swaps the two R-side grays and nothing else', () => {
    assert.equal(lf.darkEdgeColor('#64748b'), '#94a3b8');
    assert.equal(lf.darkEdgeColor('#94a3b8'), '#64748b');
    assert.equal(lf.darkEdgeColor('#ff0000'), '#ff0000');
  });

  test('themeEdge is the identity in light mode', () => {
    const e = edge('e1', 's', 'x', 't', 'a', { style: { stroke: '#64748b' } });
    assert.equal(lf.themeEdge(e, 'light'), e);
  });

  test('themeEdge recolors a copy in dark mode', () => {
    const e = edge('e1', 's', 'x', 't', 'a', {
      style: { stroke: '#64748b', strokeWidth: 2 },
      labelStyle: { fill: '#94a3b8' },
      labelBgStyle: { fill: '#ffffff' }
    });
    const before = structuredClone(e);
    const themed = lf.themeEdge(e, 'dark');
    assert.notEqual(themed, e);
    assert.deepEqual(themed.style, { stroke: '#94a3b8', strokeWidth: 2 });
    assert.deepEqual(themed.labelStyle, { fill: '#64748b' });
    assert.deepEqual(themed.labelBgStyle, { fill: '#1e1e1e' });
    assert.deepEqual(e, before);
  });

  test('themeEdge passes user styling through in dark mode', () => {
    const e = edge('e1', 's', 'x', 't', 'a', {
      style: { stroke: '#ff0000' },
      labelBgStyle: { fill: '#eeeeee' }
    });
    const themed = lf.themeEdge(e, 'dark');
    assert.equal(themed.style.stroke, '#ff0000');
    assert.equal(themed.labelBgStyle, e.labelBgStyle);
    assert.equal('style' in lf.themeEdge(edge('e2', 's', 'x', 't', 'a'), 'dark'), false);
  });
});

describe('hoverCard', () => {
  test('positions the card in container pixels with theme colors', () => {
    const t = lf.THEME_COLORS.dark;
    const card = lf.hoverCard(fakeReact, t, { left: 12, top: 34 }, 'body');
    assert.equal(card.type, 'div');
    assert.equal(card.props.style.left, '12px');
    assert.equal(card.props.style.top, '34px');
    assert.equal(card.props.style.transform, 'translateY(-50%)');
    assert.equal(card.props.style.background, t.legendBg);
    assert.equal(card.props.style.color, t.legendText);
    assert.deepEqual(card.children, ['body']);
  });

  test('flip moves the card to the left of its anchor', () => {
    const card = lf.hoverCard(fakeReact, lf.THEME_COLORS.light, { left: 0, top: 0, flip: true }, null);
    assert.equal(card.props.style.transform, 'translate(-100%, -50%)');
  });
});

describe('legendPanel', () => {
  const Panel = function Panel() {};
  const rowsOf = (panel) => panel.children[0];

  test('lists only the table types present, then the direct edge row', () => {
    const panel = lf.legendPanel(fakeReact, Panel, 'light', ['source', 'target'], false);
    assert.equal(panel.type, Panel);
    assert.equal(panel.props.position, 'top-right');
    assert.deepEqual(rowsOf(panel).map((row) => row.props.key), ['source', 'target', 'direct']);
    assert.deepEqual(rowsOf(panel).map((row) => row.children[1]), ['Source', 'Target', 'Direct']);
  });

  test('adds the indirect row only when indirect edges exist', () => {
    const panel = lf.legendPanel(fakeReact, Panel, 'light', [], true);
    assert.deepEqual(rowsOf(panel).map((row) => row.props.key), ['direct', 'indirect']);
    assert.equal(rowsOf(panel)[1].children[0].props.style.borderTop, '2px dashed #94a3b8');
  });

  test('swatches and lines follow the theme', () => {
    const light = rowsOf(lf.legendPanel(fakeReact, Panel, 'light', ['source'], true));
    assert.equal(light[0].children[0].props.style.background, '#3b82f6');
    assert.equal(light[1].children[0].props.style.borderTop, '2px solid #64748b');

    const dark = rowsOf(lf.legendPanel(fakeReact, Panel, 'dark', ['source'], true));
    assert.equal(dark[0].children[0].props.style.background, lf.DARK_NODE_PALETTES.source.border);
    assert.equal(dark[1].children[0].props.style.borderTop, '2px solid #94a3b8');
    assert.equal(dark[2].children[0].props.style.borderTop, '2px dashed #64748b');
  });
});

describe('exportPng', () => {
  // A bundle stub that records what exportPng asks of it
  function fakeBundle(rawBounds, toPngResult) {
    const calls = { toPng: [], viewport: [] };
    return {
      calls,
      getNodesBounds: () => rawBounds,
      getViewportForBounds: (...args) => {
        calls.viewport.push(args);
        return { x: 5, y: 6, zoom: 2 };
      },
      toPng: (el, options) => {
        calls.toPng.push({ el, options });
        return toPngResult || Promise.resolve('data:image/png;base64,AAAA');
      }
    };
  }

  function fakeDocument() {
    const link = { clicked: 0, removed: 0, click() { this.clicked++; }, remove() { this.removed++; } };
    const appended = [];
    return {
      link,
      appended,
      createElement: () => link,
      body: { appendChild: (node) => appended.push(node) }
    };
  }

  const viewportEl = { id: 'viewport' };
  const el = { querySelector: (sel) => (sel === '.react-flow__viewport' ? viewportEl : null) };
  const flowWith = (nodes) => ({ getNodes: () => nodes });
  const flush = () => new Promise((resolve) => setImmediate(resolve));

  test('renders the node bounds at 2x and downloads the result', async () => {
    const bundle = fakeBundle({ x: 0, y: 0, width: 952, height: 452 });
    const doc = fakeDocument();
    await withGlobals({ window: { ReactFlowBundle: bundle }, document: doc }, async () => {
      lf.exportPng(el, { flow: flowWith([{ id: 'n' }]) }, 'light');
      await flush();
    });

    // The zero padding argument is required; omitting it yields NaNs
    assert.deepEqual(bundle.calls.viewport, [[
      { x: -24, y: -24, width: 1000, height: 500 }, 2000, 1000, 2, 2, 0
    ]]);
    const call = bundle.calls.toPng[0];
    assert.equal(call.el, viewportEl);
    assert.equal(call.options.width, 2000);
    assert.equal(call.options.height, 1000);
    assert.equal(call.options.backgroundColor, lf.THEME_COLORS.light.exportBg);
    assert.equal(call.options.style.transform, 'translate(5px, 6px) scale(2)');

    assert.equal(doc.link.download, 'lineage.png');
    assert.equal(doc.link.href, 'data:image/png;base64,AAAA');
    assert.deepEqual(doc.appended, [doc.link]);
    assert.equal(doc.link.clicked, 1);
    assert.equal(doc.link.removed, 1);
  });

  test('caps giant graphs at 4096px a side', async () => {
    const bundle = fakeBundle({ x: 0, y: 0, width: 9952, height: 4952 });
    await withGlobals({ window: { ReactFlowBundle: bundle }, document: fakeDocument() }, async () => {
      lf.exportPng(el, { flow: flowWith([{ id: 'n' }]) }, 'dark');
      await flush();
    });
    const options = bundle.calls.toPng[0].options;
    assert.equal(options.width, 4096);
    assert.equal(options.height, 2048);
    assert.equal(options.backgroundColor, lf.THEME_COLORS.dark.exportBg);
  });

  test('does nothing without a flow, nodes, bundle support, or a viewport', async () => {
    const bundle = fakeBundle({ x: 0, y: 0, width: 100, height: 100 });
    const noToPng = Object.assign(fakeBundle({}), { toPng: undefined });
    await withGlobals({ window: { ReactFlowBundle: bundle }, document: fakeDocument() }, async () => {
      lf.exportPng(el, { flow: null }, 'light');
      lf.exportPng(el, { flow: flowWith([]) }, 'light');
      lf.exportPng({ querySelector: () => null }, { flow: flowWith([{ id: 'n' }]) }, 'light');
    });
    await withGlobals({ window: { ReactFlowBundle: noToPng }, document: fakeDocument() }, async () => {
      lf.exportPng(el, { flow: flowWith([{ id: 'n' }]) }, 'light');
    });
    assert.equal(bundle.calls.toPng.length, 0);
  });

  test('logs a failed export instead of throwing', async () => {
    const bundle = fakeBundle({ x: 0, y: 0, width: 100, height: 100 }, Promise.reject(new Error('boom')));
    const logged = [];
    const fakeConsole = Object.assign({}, console, { error: (...args) => logged.push(args) });
    await withGlobals(
      { window: { ReactFlowBundle: bundle }, document: fakeDocument(), console: fakeConsole },
      async () => {
        lf.exportPng(el, { flow: flowWith([{ id: 'n' }]) }, 'light');
        await flush();
      }
    );
    assert.equal(logged.length, 1);
    assert.equal(logged[0][1].message, 'boom');
  });
});

describe('watchContainerSize', () => {
  // Captures the observer callback and queues animation frames so a test
  // can fire them by hand
  function browser() {
    const b = { observers: [], frames: [], cancelled: [] };
    b.globals = {
      ResizeObserver: class {
        constructor(callback) { this.callback = callback; this.observed = []; b.observers.push(this); }
        observe(target) { this.observed.push(target); }
        disconnect() { this.disconnected = true; }
      },
      requestAnimationFrame: (callback) => { b.frames.push(callback); return b.frames.length; },
      cancelAnimationFrame: (id) => { b.cancelled.push(id); }
    };
    b.fire = () => b.observers[0].callback();
    return b;
  }

  function flowWith(nodes) {
    const flow = { fits: [], getNodes: () => nodes, fitView: (options) => flow.fits.push(options) };
    return flow;
  }

  const measuredNode = { measured: { width: 200, height: 77 } };

  test('does nothing where ResizeObserver is missing', () => {
    const state = { flow: null, fitObserver: null, fitRaf: null };
    lf.watchContainerSize({ offsetWidth: 800, offsetHeight: 600 }, state);
    assert.equal(state.fitObserver, null);
  });

  test('re-fits when the container size changes, not when it repeats', async () => {
    const b = browser();
    const el = { offsetWidth: 800, offsetHeight: 600 };
    const state = { flow: flowWith([measuredNode]), fitObserver: null, fitRaf: null };
    await withGlobals(b.globals, () => {
      lf.watchContainerSize(el, state);
      assert.deepEqual(state.fitObserver.observed, [el]);
      b.fire();
      b.fire();
      assert.deepEqual(state.flow.fits, [lf.FIT_VIEW_OPTIONS]);
      el.offsetWidth = 1000;
      b.fire();
      assert.equal(state.flow.fits.length, 2);
    });
  });

  test('ignores a collapsed container', async () => {
    const b = browser();
    const state = { flow: flowWith([measuredNode]), fitObserver: null, fitRaf: null };
    await withGlobals(b.globals, () => {
      lf.watchContainerSize({ offsetWidth: 0, offsetHeight: 600 }, state);
      b.fire();
      assert.equal(state.flow.fits.length, 0);
      assert.equal(b.frames.length, 0);
    });
  });

  test('waits on animation frames until the nodes are measured', async () => {
    const b = browser();
    const nodes = [{ measured: null }];
    const state = { flow: flowWith(nodes), fitObserver: null, fitRaf: null };
    await withGlobals(b.globals, () => {
      lf.watchContainerSize({ offsetWidth: 800, offsetHeight: 600 }, state);
      b.fire();
      assert.equal(state.flow.fits.length, 0);
      assert.equal(state.fitRaf, 1);

      nodes[0] = measuredNode;
      b.frames.shift()();
      assert.equal(state.flow.fits.length, 1);
      assert.equal(state.fitRaf, null);
    });
  });

  test('gives up after 60 frames without measurements', async () => {
    const b = browser();
    const state = { flow: flowWith([]), fitObserver: null, fitRaf: null };
    await withGlobals(b.globals, () => {
      lf.watchContainerSize({ offsetWidth: 800, offsetHeight: 600 }, state);
      b.fire();
      let ran = 0;
      while (b.frames.length > 0) {
        b.frames.shift()();
        ran++;
      }
      assert.equal(ran, 60);
      assert.equal(state.flow.fits.length, 0);
    });
  });

  test('a new resize cancels the pending retry', async () => {
    const b = browser();
    const state = { flow: flowWith([]), fitObserver: null, fitRaf: null };
    await withGlobals(b.globals, () => {
      lf.watchContainerSize({ offsetWidth: 800, offsetHeight: 600 }, state);
      b.fire();
      b.fire();
      assert.deepEqual(b.cancelled, [1]);
    });
  });
});

describe('SVG helpers', () => {
  test('escapeHtml covers the characters that matter inside markup and attributes', () => {
    assert.equal(
      lf.escapeHtml('<a href="x">&</a>'),
      '&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;'
    );
    assert.equal(lf.escapeHtml(2), '2');
  });

  test('svgColumnsOf always returns an array', () => {
    assert.deepEqual(lf.svgColumnsOf({ data: { columns: ['a', 'b'] } }), ['a', 'b']);
    assert.deepEqual(lf.svgColumnsOf({ data: { columns: 'a' } }), ['a']);
    assert.deepEqual(lf.svgColumnsOf({}), []);
  });

  test('node height is the header plus one row per column', () => {
    assert.equal(lf.svgNodeHeight({ data: { columns: ['a', 'b'] } }), lf.SVG_HEADER_H + 2 * lf.SVG_ROW_H);
    assert.equal(lf.svgNodeHeight({}), lf.SVG_HEADER_H);
  });

  test('edges anchor at the row center, or the header for an unknown handle', () => {
    const node = { position: { x: 0, y: 100 }, data: { columns: ['a', 'b'] } };
    assert.equal(lf.svgAnchorY(node, 'b'), 100 + lf.SVG_HEADER_H + lf.SVG_ROW_H + lf.SVG_ROW_H / 2);
    assert.equal(lf.svgAnchorY(node, 'zz'), 100 + lf.SVG_HEADER_H / 2);
  });

  test('svgTruncate trims to the limit with an ellipsis', () => {
    assert.equal(lf.svgTruncate('short', 10), 'short');
    assert.equal(lf.svgTruncate('exactly-10', 10), 'exactly-10');
    const cut = lf.svgTruncate('abcdefghijklmnop', 10);
    assert.equal(cut, 'abcdefghi…');
    assert.equal(cut.length, 10);
    assert.equal(lf.svgTruncate(12345, 3), '12…');
  });
});

describe('renderSVG', () => {
  function render(x, elProps, height) {
    const el = Object.assign({ offsetHeight: 0, innerHTML: '' }, elProps);
    lf.renderSVG(el, x, 800, height);
    return el.innerHTML;
  }

  const source = {
    id: 'orders',
    position: { x: 0, y: 0 },
    data: { label: 'orders', columns: ['id', 'amount'], tableType: 'source',
            colors: { bg: '#f0f7ff', border: '#3b82f6', header: '#1d4ed8' } }
  };
  const target = {
    id: 'summary',
    position: { x: 250, y: 0 },
    data: { label: 'summary', columns: ['total'], tableType: 'target',
            colors: { bg: '#f0fdf4', border: '#10b981', header: '#059669' } }
  };

  test('an empty graph draws a default frame', () => {
    const html = render({});
    assert.ok(html.startsWith('<svg '));
    assert.ok(html.includes('viewBox="-20 -20 840 240"'));
    assert.ok(html.includes('<defs></defs>'));
    assert.ok(html.includes('Tables: 0 | Edges: 0'));
  });

  test('the frame hugs the nodes with 20px of padding', () => {
    const html = render({ nodes: [source, target] });
    // widest extent: target x (250) + node width; tallest: source, two rows
    const w = 250 + lf.SVG_NODE_W + 40;
    const h = lf.SVG_HEADER_H + 2 * lf.SVG_ROW_H + 40;
    assert.ok(html.includes('viewBox="-20 -20 ' + w + ' ' + h + '"'));
    assert.ok(html.includes('Tables: 2 | Edges: 0'));
  });

  test('height comes from the element, then the argument, with a 200px floor', () => {
    assert.ok(render({}, { offsetHeight: 644 }).includes('height="600"'));
    assert.ok(render({}, {}, 500).includes('height="456"'));
    assert.ok(render({}, {}).includes('height="356"'));
    assert.ok(render({}, { offsetHeight: 100 }).includes('height="200"'));
  });

  test('an edge runs from the source row to just short of the target row', () => {
    const html = render({
      nodes: [source, target],
      edges: [edge('e1', 'orders', 'amount', 'summary', 'total')]
    });
    // amount is row 1 of orders, total is row 0 of summary; a short span
    // falls back to the 40px minimum control-point offset
    const y1 = lf.SVG_HEADER_H + lf.SVG_ROW_H + lf.SVG_ROW_H / 2;
    const y2 = lf.SVG_HEADER_H + lf.SVG_ROW_H / 2;
    assert.ok(html.includes(
      '<path d="M 200 ' + y1 + ' C 240 ' + y1 + ', 204 ' + y2 + ', 244 ' + y2 + '"'
    ));
    assert.ok(html.includes('stroke="#64748b" stroke-width="2"'));
    assert.ok(html.includes('marker-end="url(#lineage-arrow-64748b)"'));
  });

  test('a long span scales the control points to 40% of the distance', () => {
    const far = Object.assign({}, target, { position: { x: 1006, y: 0 } });
    const html = render({
      nodes: [source, far],
      edges: [edge('e1', 'orders', 'id', 'summary', 'total')]
    });
    const d = html.split('<path d="')[1].split('"')[0];
    const numbers = d.split(/[ ,MC]+/).filter(Boolean).map(Number);
    // M x1 y1 C c1x c1y, c2x c2y, x2 y2 with x1 = 200 and x2 = 1000
    near(numbers[2], 200 + 320);
    near(numbers[4], 1000 - 320);
  });

  test('one arrowhead marker per distinct edge color', () => {
    const html = render({
      nodes: [source, target],
      edges: [
        edge('e1', 'orders', 'id', 'summary', 'total'),
        edge('e2', 'orders', 'amount', 'summary', 'total'),
        edge('e3', 'orders', 'amount', 'summary', 'total', {
          style: { stroke: '#94a3b8', strokeDasharray: '5 5', strokeWidth: 1 }
        })
      ]
    });
    assert.equal(html.split('<marker ').length - 1, 2);
    assert.ok(html.includes('stroke-dasharray="5 5"'));
    assert.ok(html.includes('stroke="#94a3b8" stroke-width="1"'));
  });

  test('an edge with a missing endpoint is skipped but still counted', () => {
    const html = render({
      nodes: [source],
      edges: [edge('e1', 'orders', 'id', 'nowhere', 'x')]
    });
    assert.equal(html.includes('<path '), false);
    assert.ok(html.includes('Tables: 1 | Edges: 1'));
  });

  test('labels, columns, and tooltips are escaped before reaching innerHTML', () => {
    const hostile = {
      id: 'n',
      position: { x: 0, y: 0 },
      data: {
        label: '<script>x</script>',
        columns: ['"><img src=x>'],
        columnTypes: { '"><img src=x>': '<i>int</i>' },
        columnLabels: { '"><img src=x>': 'A & B' }
      }
    };
    const html = render({ nodes: [hostile] });
    assert.equal(html.includes('<script'), false);
    assert.equal(html.includes('<img'), false);
    assert.equal(html.includes('<i>'), false);
    assert.ok(html.includes('&lt;script&gt;x&lt;/script&gt;'));
    assert.ok(html.includes(
      '<title>&quot;&gt;&lt;img src=x&gt; — &lt;i&gt;int&lt;/i&gt;\nA &amp; B</title>'
    ));
  });

  test('rows without metadata get no tooltip', () => {
    assert.equal(render({ nodes: [source] }).includes('<title>'), false);
  });

  test('a node without colors or a label falls back to source blue and its id', () => {
    const bare = { id: 'a_table_name_well_beyond_the_limit', position: { x: 0, y: 0 } };
    const html = render({ nodes: [bare] });
    assert.ok(html.includes('fill="#f0f7ff"'));
    assert.ok(html.includes('>a_table_name_well_bey…</text>'));
  });

  test('dark theme swaps the canvas, the default edge gray, and node palettes', () => {
    const html = render({
      nodes: [source, target],
      edges: [edge('e1', 'orders', 'id', 'summary', 'total')],
      options: { theme: 'dark' }
    });
    assert.ok(html.includes('background: #141414'));
    assert.ok(html.includes('marker-end="url(#lineage-arrow-94a3b8)"'));
    assert.ok(html.includes('fill="' + lf.DARK_NODE_PALETTES.source.bg + '"'));
    assert.ok(html.includes('fill="' + lf.THEME_COLORS.dark.text + '"'));
  });

  test('theme "auto" resolves once from prefers-color-scheme', async () => {
    const prefersDark = { matchMedia: () => ({ matches: true }) };
    const prefersLight = { matchMedia: () => ({ matches: false }) };
    await withGlobals({ window: prefersDark }, () => {
      assert.ok(render({ options: { theme: 'auto' } }).includes('background: #141414'));
    });
    await withGlobals({ window: prefersLight }, () => {
      assert.ok(render({ options: { theme: 'auto' } }).includes('background: #fafafa'));
    });
    await withGlobals({ window: {} }, () => {
      assert.ok(render({ options: { theme: 'auto' } }).includes('background: #fafafa'));
    });
  });
});

describe('widget binding', () => {
  const payload = {
    nodes: [{ id: 'n', position: { x: 0, y: 0 }, data: { label: 'n', columns: ['a'] } }],
    edges: []
  };

  test('registers as the lineage_flow output widget', () => {
    assert.equal(widgetDef.name, 'lineage_flow');
    assert.equal(widgetDef.type, 'output');
  });

  test('falls back to the static SVG when the React Flow bundle is absent', async () => {
    const el = { offsetWidth: 800, offsetHeight: 600, innerHTML: '' };
    await withGlobals({ window: {} }, () => {
      const instance = widgetDef.factory(el, 800, 600);
      instance.renderValue(payload);
      instance.resize(400, 300);
    });
    assert.ok(el.innerHTML.includes('Column lineage (static SVG) | Tables: 1'));
  });

  test('a hidden container defers the first render until it has a size', async () => {
    const observers = [];
    class FakeResizeObserver {
      constructor(callback) { this.callback = callback; this.observed = []; observers.push(this); }
      observe(target) { this.observed.push(target); }
      disconnect() { this.disconnected = true; }
    }
    const el = { offsetWidth: 0, offsetHeight: 0, innerHTML: '' };
    await withGlobals({ window: {}, ResizeObserver: FakeResizeObserver }, () => {
      const instance = widgetDef.factory(el, 800, 600);
      instance.renderValue(payload);
      assert.equal(el.innerHTML, '');
      assert.deepEqual(observers[0].observed, [el]);

      // still hidden: keep waiting
      observers[0].callback();
      assert.equal(el.innerHTML, '');

      // a re-render while waiting replaces the pending observer
      instance.renderValue(payload);
      assert.equal(observers[0].disconnected, true);
      assert.equal(observers.length, 2);

      el.offsetWidth = 800;
      el.offsetHeight = 600;
      observers[1].callback();
      assert.ok(el.innerHTML.includes('<svg '));
      assert.equal(observers[1].disconnected, true);
    });
  });
});
