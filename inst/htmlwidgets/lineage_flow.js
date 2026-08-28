var FIT_VIEW_OPTIONS = { padding: 0.2 };

HTMLWidgets.widget({
  name: 'lineage_flow',
  type: 'output',
  factory: function(el, width, height) {
    // flow is set by renderReactFlow's onInit; observer waits out hidden
    // containers before the first render; root/container track the React
    // mount so re-renders can unmount it first
    var state = { flow: null, observer: null, root: null, container: null };

    function render(x) {
      if (typeof window.ReactFlowBundle !== 'undefined') {
        renderReactFlow(el, x, width, height, state);
      } else {
        renderSVG(el, x, width, height);
      }
    }

    return {
      renderValue: function(x) {
        if (state.observer) {
          state.observer.disconnect();
          state.observer = null;
        }
        // Unmount the previous React tree (Shiny re-renders call
        // renderValue again) so its effects — the Escape listener — are
        // cleaned up instead of orphaned by the innerHTML wipe
        if (state.root) {
          try { state.root.unmount(); } catch (e) {}
          state.root = null;
        } else if (state.container && typeof window.ReactFlowBundle !== 'undefined' &&
                   window.ReactFlowBundle.ReactDOM.unmountComponentAtNode) {
          try {
            window.ReactFlowBundle.ReactDOM.unmountComponentAtNode(state.container);
          } catch (e) {}
        }
        state.container = null;
        state.flow = null;

        // React Flow mounted inside a hidden container (a non-active
        // reveal.js slide, a hidden tabset panel) records zero dimensions
        // and pins the viewport at minZoom, where later fitView calls
        // no-op. Wait for real dimensions before the first render.
        var hasSize = el.offsetWidth > 0 && el.offsetHeight > 0;
        if (hasSize || typeof ResizeObserver === 'undefined') {
          render(x);
          return;
        }
        var observer = new ResizeObserver(function() {
          if (el.offsetWidth > 0 && el.offsetHeight > 0) {
            observer.disconnect();
            state.observer = null;
            render(x);
          }
        });
        state.observer = observer;
        observer.observe(el);
      },
      resize: function(width, height) {
        // React Flow tracks its own wrapper size, so a container resize
        // only needs the graph re-fit into the new frame
        if (state.flow) {
          state.flow.fitView(FIT_VIEW_OPTIONS);
        }
      }
    };
  }
});

// Assign each target column its own vertical "lane" (a fraction of the
// horizontal span between source and target) so parallel smoothstep edges
// don't draw on top of each other. Edges fanning into the same target
// column share a lane deliberately, so they read as a merge.
function computeLaneFractions(nodes, edges) {
  var columnOrder = {};
  nodes.forEach(function(node) {
    var cols = (node.data && node.data.columns) || [];
    if (!Array.isArray(cols)) {
      cols = [cols];
    }
    var lookup = {};
    cols.forEach(function(col, i) { lookup[col] = i; });
    columnOrder[node.id] = lookup;
  });

  // Distinct target columns per target node
  var groups = {};
  edges.forEach(function(edge) {
    if (!groups[edge.target]) {
      groups[edge.target] = [];
    }
    if (groups[edge.target].indexOf(edge.targetHandle) === -1) {
      groups[edge.target].push(edge.targetHandle);
    }
  });

  var fractions = {};
  Object.keys(groups).forEach(function(target) {
    var handles = groups[target];
    var order = columnOrder[target] || {};
    handles.sort(function(a, b) {
      var ia = order[a] !== undefined ? order[a] : Infinity;
      var ib = order[b] !== undefined ? order[b] : Infinity;
      return ia - ib;
    });
    var n = handles.length;
    handles.forEach(function(handle, idx) {
      // Top target rows take the lanes nearest the target so elbows nest
      // instead of crossing when sources and targets share row order
      var i = n - 1 - idx;
      // Spread across the middle of the corridor; a single lane sits at
      // 0.5, matching a plain smoothstep edge
      fractions[target + '\u0000' + handle] = 0.2 + 0.6 * (i + 1) / (n + 1);
    });
  });
  return fractions;
}

// Column-level adjacency in both directions, keyed like the lane table
// (nodeId NUL handle). Each step remembers the edge it rode so the cone
// can restyle exactly the traversed edges.
function buildAdjacency(edges) {
  var out = {};
  var inn = {};
  edges.forEach(function(edge) {
    var s = edge.source + '\u0000' + edge.sourceHandle;
    var t = edge.target + '\u0000' + edge.targetHandle;
    if (!out[s]) {
      out[s] = [];
    }
    out[s].push({ key: t, edgeId: edge.id });
    if (!inn[t]) {
      inn[t] = [];
    }
    inn[t].push({ key: s, edgeId: edge.id });
  });
  return { out: out, inn: inn };
}

function walkCone(adj, startKey, columnKeys, edgeIds) {
  var frontier = [startKey];
  while (frontier.length > 0) {
    var next = [];
    frontier.forEach(function(key) {
      (adj[key] || []).forEach(function(step) {
        edgeIds[step.edgeId] = true;
        if (!columnKeys[step.key]) {
          columnKeys[step.key] = true;
          next.push(step.key);
        }
      });
    });
    frontier = next;
  }
}

// The transitive upstream + downstream subgraph of one column: the same
// walk as R's bfs_reachable(), run both ways. Only traversed edges join
// the cone, so cross-links between cone members that bypass the anchor
// stay dimmed.
function computeCone(adjacency, selected) {
  var startKey = selected.nodeId + '\u0000' + selected.handleId;
  var columnKeys = {};
  columnKeys[startKey] = true;
  var edgeIds = {};
  walkCone(adjacency.out, startKey, columnKeys, edgeIds);
  walkCone(adjacency.inn, startKey, columnKeys, edgeIds);
  var nodeIds = {};
  Object.keys(columnKeys).forEach(function(key) {
    nodeIds[key.split('\u0000')[0]] = true;
  });
  return { columnKeys: columnKeys, edgeIds: edgeIds, nodeIds: nodeIds };
}

// Node colors are frozen into the payload by R (light values); dark mode
// remaps them at render time by tableType so the same lineage object can
// draw in either theme. Border hues stay recognizable across themes.
var DARK_NODE_PALETTES = {
  source: { bg: '#172554', border: '#60a5fa', header: '#1e40af' },
  transform: { bg: '#451a03', border: '#fbbf24', header: '#b45309' },
  target: { bg: '#022c22', border: '#34d399', header: '#047857' }
};

var THEME_COLORS = {
  light: {
    nodeBg: 'white', text: '#1f2937', rowBorder: '#e5e7eb',
    hoverBg: '#ffffff', selectedBg: '#fef3c7',
    edgeHighlight: '#f59e0b', edgeDim: '#d1d5db', edgeDimOpacity: 0.3,
    backgroundDots: '#d1d5db', exportBg: '#ffffff',
    legendBg: 'rgba(255, 255, 255, 0.92)', legendBorder: '#e5e7eb',
    legendText: '#374151'
  },
  dark: {
    nodeBg: '#1e1e1e', text: '#e5e7eb', rowBorder: '#374151',
    hoverBg: '#374151', selectedBg: '#78350f',
    edgeHighlight: '#fbbf24', edgeDim: '#4b5563', edgeDimOpacity: 0.35,
    backgroundDots: '#3f3f46', exportBg: '#141414',
    legendBg: 'rgba(30, 30, 30, 0.92)', legendBorder: '#3f3f46',
    legendText: '#d1d5db'
  }
};

function themeNodeColors(node, theme) {
  var base = (node.data && node.data.colors) || {};
  if (theme !== 'dark') {
    return base;
  }
  var typed = DARK_NODE_PALETTES[node.data && node.data.tableType];
  if (!typed) {
    // A type outside source/transform/target has no dark palette; its
    // light colors stay self-consistent (light text on light rows)
    return base;
  }
  var t = THEME_COLORS.dark;
  return Object.assign({}, base, typed, {
    nodeBg: t.nodeBg, text: t.text, rowBorder: t.rowBorder,
    hoverBg: t.hoverBg, selectedBg: t.selectedBg
  });
}

// The two R-side edge grays swap roles on a dark canvas ("fainter"
// inverts); anything else — user-styled edges — passes through untouched
function darkEdgeColor(color) {
  if (color === '#64748b') return '#94a3b8';
  if (color === '#94a3b8') return '#64748b';
  return color;
}

function themeEdge(edge, theme) {
  if (theme !== 'dark') {
    return edge;
  }
  var out = Object.assign({}, edge);
  if (edge.style && edge.style.stroke) {
    out.style = Object.assign({}, edge.style, {
      stroke: darkEdgeColor(edge.style.stroke)
    });
  }
  if (edge.labelStyle && edge.labelStyle.fill) {
    out.labelStyle = Object.assign({}, edge.labelStyle, {
      fill: darkEdgeColor(edge.labelStyle.fill)
    });
  }
  if (edge.labelBgStyle && edge.labelBgStyle.fill === '#ffffff') {
    out.labelBgStyle = Object.assign({}, edge.labelBgStyle, {
      fill: '#1e1e1e'
    });
  }
  return out;
}

// Small overlay naming the node colors and edge styles in play
function legendPanel(React, Panel, theme, presentTypes, hasIndirect) {
  var t = THEME_COLORS[theme];
  var rowStyle = {
    display: 'flex',
    alignItems: 'center',
    gap: '6px',
    lineHeight: '16px'
  };
  function chipStyle(color) {
    return {
      display: 'inline-block',
      width: '10px',
      height: '10px',
      borderRadius: '3px',
      background: color,
      flex: 'none'
    };
  }
  function lineStyle(color, dashed) {
    return {
      display: 'inline-block',
      width: '16px',
      borderTop: '2px ' + (dashed ? 'dashed' : 'solid') + ' ' + color,
      flex: 'none'
    };
  }
  var labels = { source: 'Source', transform: 'Transform', target: 'Target' };
  var children = presentTypes.map(function(type) {
    var swatch = theme === 'dark'
      ? DARK_NODE_PALETTES[type].border
      : { source: '#3b82f6', transform: '#f59e0b', target: '#10b981' }[type];
    return React.createElement('div', { key: type, style: rowStyle },
      React.createElement('span', { style: chipStyle(swatch) }),
      labels[type]
    );
  });
  children.push(React.createElement('div', { key: 'direct', style: rowStyle },
    React.createElement('span', {
      style: lineStyle(theme === 'dark' ? '#94a3b8' : '#64748b', false)
    }),
    'Direct'
  ));
  if (hasIndirect) {
    children.push(React.createElement('div', { key: 'indirect', style: rowStyle },
      React.createElement('span', {
        style: lineStyle(theme === 'dark' ? '#64748b' : '#94a3b8', true)
      }),
      'Indirect'
    ));
  }
  return React.createElement(Panel, {
    position: 'top-right',
    style: {
      background: t.legendBg,
      border: '1px solid ' + t.legendBorder,
      borderRadius: '6px',
      padding: '8px 10px',
      fontSize: '11px',
      fontFamily: 'system-ui, -apple-system, sans-serif',
      color: t.legendText,
      display: 'flex',
      flexDirection: 'column',
      gap: '4px',
      margin: '10px'
    }
  }, children);
}

// Renders the whole graph to a PNG and hands it to the browser as a
// download. Runs outside React off the instance captured by onInit.
function exportPng(el, state, theme) {
  var B = window.ReactFlowBundle;
  if (!state.flow || !B.toPng || !B.getNodesBounds || !B.getViewportForBounds) {
    return;
  }
  var nodes = state.flow.getNodes();
  if (!nodes.length) {
    return;
  }
  var raw = B.getNodesBounds(nodes);
  var pad = 24;
  var bounds = {
    x: raw.x - pad,
    y: raw.y - pad,
    width: raw.width + 2 * pad,
    height: raw.height + 2 * pad
  };
  // 2x for crispness, capped so giant graphs stay under 4096px a side
  var scale = Math.min(2, 4096 / bounds.width, 4096 / bounds.height);
  var w = Math.round(bounds.width * scale);
  var h = Math.round(bounds.height * scale);
  // The 6th padding argument is required: omitting it yields NaNs
  var viewport = B.getViewportForBounds(bounds, w, h, scale, scale, 0);
  // Scoped to this widget: multiple widgets can render on one page, and
  // the viewport layer holds only nodes and edges, so controls, minimap,
  // legend, and the dotted background stay out of the image
  var viewportEl = el.querySelector('.react-flow__viewport');
  if (!viewportEl) {
    return;
  }
  B.toPng(viewportEl, {
    backgroundColor: THEME_COLORS[theme].exportBg,
    width: w,
    height: h,
    pixelRatio: 1,
    skipFonts: true,
    style: {
      width: w + 'px',
      height: h + 'px',
      transform: 'translate(' + viewport.x + 'px, ' + viewport.y + 'px) scale(' + viewport.zoom + ')'
    }
  }).then(function(dataUrl) {
    var link = document.createElement('a');
    link.download = 'lineage.png';
    link.href = dataUrl;
    document.body.appendChild(link);
    link.click();
    link.remove();
  }).catch(function(e) {
    console.error('lineage_flow PNG export failed:', e);
  });
}

function renderReactFlow(el, x, width, height, state) {
  var React = window.ReactFlowBundle.React;
  var ReactDOM = window.ReactFlowBundle.ReactDOM;
  var ReactFlow = window.ReactFlowBundle.ReactFlow;
  var Background = window.ReactFlowBundle.Background;
  var Controls = window.ReactFlowBundle.Controls;
  var applyNodeChanges = window.ReactFlowBundle.applyNodeChanges;
  var applyEdgeChanges = window.ReactFlowBundle.applyEdgeChanges;
  var TableNode = window.ReactFlowBundle.TableNode;
  var LineageEdge = window.ReactFlowBundle.LineageEdge;
  // Chrome that only newer bundles export; each is guarded at use so an
  // older cached bundle degrades by omission instead of crashing
  var ControlButton = window.ReactFlowBundle.ControlButton;
  var MiniMap = window.ReactFlowBundle.MiniMap;
  var Panel = window.ReactFlowBundle.Panel;
  var canExportPng = !!(ControlButton && window.ReactFlowBundle.toPng &&
    window.ReactFlowBundle.getNodesBounds && window.ReactFlowBundle.getViewportForBounds);
  // Older cached bundles don't export LineageEdge; fall back to smoothstep
  var defaultEdgeType = LineageEdge ? 'lineage' : 'smoothstep';

  var opts = x.options || {};

  el.style.width = '100%';
  // htmlwidgets sets an inline height on el; default only when embedding
  // outside that machinery leaves it unset (the factory's height is 0 for
  // a container that initialized hidden, so it can't be trusted here)
  if (!el.style.height) {
    el.style.height = height ? height + 'px' : '600px';
  }
  // Class rather than id: multiple widgets can render on one page
  el.innerHTML = '<div class="lineage-flow-container" style="width: 100%; height: 100%;"></div>';

  var container = el.querySelector('.lineage-flow-container');
  
  // Define custom node types
  var nodeTypes = {
    tableNode: TableNode
  };

  var edgeTypes = LineageEdge ? { lineage: LineageEdge } : {};

  // Ensure nodes are connectable with default styling
  var initialNodes = (x.nodes || []).map(function(node) {
    return Object.assign({}, node, {
      type: node.type || 'default',
      draggable: true
    });
  });

  var laneFractions = computeLaneFractions(x.nodes || [], x.edges || []);
  var adjacency = buildAdjacency(x.edges || []);

  // Legend content reflects what the graph actually contains
  var presentTypes = ['source', 'transform', 'target'].filter(function(type) {
    return (x.nodes || []).some(function(node) {
      return node.data && node.data.tableType === type;
    });
  });
  var hasIndirect = (x.edges || []).some(function(edge) {
    return edge.style && edge.style.strokeDasharray;
  });

  var initialEdges = (x.edges || []).map(function(edge) {
    var data = Object.assign({}, edge.data);
    if (typeof data.laneFraction !== 'number') {
      var lane = laneFractions[edge.target + '\u0000' + edge.targetHandle];
      if (lane !== undefined) {
        data.laneFraction = lane;
      }
    }
    return Object.assign({}, edge, {
      type: edge.type || defaultEdgeType,
      animated: edge.animated || false,
      data: data
    });
  });
  
  try {
    var FlowComponent = function() {
      var useState = React.useState;
      var useCallback = React.useCallback;
      var useMemo = React.useMemo;
      var useEffect = React.useEffect;

      var nodesState = useState(initialNodes);
      var nodes = nodesState[0];
      var setNodes = nodesState[1];

      var edgesState = useState(initialEdges);
      var edges = edgesState[0];
      var setEdges = edgesState[1];

      // State for tracking hovered column
      var hoveredHandleState = useState(null);
      var hoveredHandle = hoveredHandleState[0];
      var setHoveredHandle = hoveredHandleState[1];

      // Clicked column whose upstream/downstream cone is isolated
      var selectedColumnState = useState(null);
      var selectedColumn = selectedColumnState[0];
      var setSelectedColumn = selectedColumnState[1];

      // Callback for when a column is hovered
      var onColumnHover = useCallback(function(nodeId, handleId) {
        if (nodeId && handleId) {
          setHoveredHandle({ nodeId: nodeId, handleId: handleId });
        } else {
          setHoveredHandle(null);
        }
      }, []);

      // Clicking a column traces its cone; clicking it again releases it
      var onColumnClick = useCallback(function(nodeId, handleId) {
        setSelectedColumn(function(prev) {
          if (prev && prev.nodeId === nodeId && prev.handleId === handleId) {
            return null;
          }
          return { nodeId: nodeId, handleId: handleId };
        });
      }, []);

      // Escape releases the traced cone from anywhere on the page
      useEffect(function() {
        function onKeyDown(event) {
          if (event.key === 'Escape') {
            setSelectedColumn(null);
          }
        }
        document.addEventListener('keydown', onKeyDown);
        return function() {
          document.removeEventListener('keydown', onKeyDown);
        };
      }, []);

      // Resolved theme. "auto" tracks prefers-color-scheme live; resolving
      // it here rather than passing colorMode "system" keeps React Flow's
      // chrome and our own palette flipping in the same render
      var prefersDarkState = useState(function() {
        return !!(window.matchMedia &&
          window.matchMedia('(prefers-color-scheme: dark)').matches);
      });
      var prefersDark = prefersDarkState[0];
      var setPrefersDark = prefersDarkState[1];
      useEffect(function() {
        if (opts.theme !== 'auto' || !window.matchMedia) {
          return undefined;
        }
        var query = window.matchMedia('(prefers-color-scheme: dark)');
        function onChange(event) {
          setPrefersDark(event.matches);
        }
        if (query.addEventListener) {
          query.addEventListener('change', onChange);
          return function() { query.removeEventListener('change', onChange); };
        }
        query.addListener(onChange);
        return function() { query.removeListener(onChange); };
      }, []);
      var theme = opts.theme === 'dark' || (opts.theme === 'auto' && prefersDark)
        ? 'dark'
        : 'light';
      var themeColors = THEME_COLORS[theme];

      var coneInfo = useMemo(function() {
        if (!selectedColumn) {
          return null;
        }
        return computeCone(adjacency, selectedColumn);
      }, [selectedColumn]);

      // Report the traced column to Shiny as input$<outputId>_selected;
      // the initial run publishes null so the input always exists
      useEffect(function() {
        if (window.Shiny && window.Shiny.setInputValue && el.id) {
          window.Shiny.setInputValue(
            el.id + '_selected',
            selectedColumn
              ? { table: selectedColumn.nodeId, column: selectedColumn.handleId }
              : null
          );
        }
      }, [selectedColumn]);

      // Update nodes to inject the callbacks, per-node cone state, and the
      // theme-resolved palette
      var nodesWithCallback = useMemo(function() {
        return nodes.map(function(node) {
          var dimmed = false;
          var dimmedColumns = [];
          var selected = null;
          if (coneInfo) {
            dimmed = !coneInfo.nodeIds[node.id];
            if (!dimmed) {
              var cols = (node.data && node.data.columns) || [];
              if (!Array.isArray(cols)) {
                cols = [cols];
              }
              dimmedColumns = cols.filter(function(col) {
                return !coneInfo.columnKeys[node.id + '\u0000' + col];
              });
            }
            if (selectedColumn && selectedColumn.nodeId === node.id) {
              selected = selectedColumn.handleId;
            }
          }
          return Object.assign({}, node, {
            data: Object.assign({}, node.data, {
              colors: themeNodeColors(node, theme),
              onColumnHover: onColumnHover,
              onColumnClick: onColumnClick,
              dimmed: dimmed,
              dimmedColumns: dimmedColumns,
              selectedColumn: selected
            })
          });
        });
      }, [nodes, onColumnHover, onColumnClick, coneInfo, selectedColumn, theme]);

      // Edge base styles re-grounded for the resolved theme
      var themedEdges = useMemo(function() {
        if (theme !== 'dark') {
          return edges;
        }
        return edges.map(function(edge) {
          return themeEdge(edge, theme);
        });
      }, [edges, theme]);

      // Update edges from the traced cone and the hovered handle. Cone
      // dimming wins: hovering never resurrects an edge outside the cone,
      // and in-cone edges stay at full strength unless hover-highlighted.
      var styledEdges = useMemo(function() {
        if (!hoveredHandle && !coneInfo) {
          return themedEdges;
        }

        return themedEdges.map(function(edge) {
          if (coneInfo && !coneInfo.edgeIds[edge.id]) {
            return Object.assign({}, edge, {
              animated: false,
              style: Object.assign({}, edge.style, { opacity: 0.15 })
            });
          }

          // Check if this edge is connected to the hovered handle
          var isConnected = hoveredHandle && (
            (edge.source === hoveredHandle.nodeId && edge.sourceHandle === hoveredHandle.handleId) ||
            (edge.target === hoveredHandle.nodeId && edge.targetHandle === hoveredHandle.handleId)
          );

          // Merge over the edge's own style so per-edge patterns
          // (e.g. the dashes on indirect edges) survive highlighting
          if (isConnected) {
            return Object.assign({}, edge, {
              animated: true,
              style: Object.assign({}, edge.style, {
                stroke: themeColors.edgeHighlight,
                strokeWidth: 3
              })
            });
          }
          if (coneInfo) {
            return edge;
          }
          return Object.assign({}, edge, {
            animated: false,
            style: Object.assign({}, edge.style, {
              stroke: themeColors.edgeDim,
              strokeWidth: 2,
              opacity: themeColors.edgeDimOpacity
            })
          });
        });
      }, [themedEdges, hoveredHandle, coneInfo, themeColors]);
      
      // Handle node changes (dragging, selecting, etc.)
      var onNodesChange = useCallback(function(changes) {
        setNodes(function(nds) {
          return applyNodeChanges(changes, nds);
        });
      }, []);
      
      // Handle edge changes (selecting, removing, etc.)
      var onEdgesChange = useCallback(function(changes) {
        setEdges(function(eds) {
          return applyEdgeChanges(changes, eds);
        });
      }, []);
      
      return React.createElement(
        ReactFlow,
        {
          nodes: nodesWithCallback,
          edges: styledEdges,
          onNodesChange: onNodesChange,
          onEdgesChange: onEdgesChange,
          nodeTypes: nodeTypes,
          edgeTypes: edgeTypes,
          onInit: function(flow) {
            state.flow = flow;
          },
          // Clicking the background releases the traced cone
          onPaneClick: function() {
            setSelectedColumn(null);
          },
          fitView: true,
          fitViewOptions: FIT_VIEW_OPTIONS,
          colorMode: theme,
          minZoom: 0.1,
          maxZoom: 4,
          nodesDraggable: true,
          // A lineage diagram states provenance; viewers must not be able
          // to draw new edges into it, and Backspace on a selected node
          // must not delete it
          nodesConnectable: false,
          deleteKeyCode: null,
          elementsSelectable: true,
          snapToGrid: true,
          snapGrid: [15, 15],
          defaultEdgeOptions: {
            type: defaultEdgeType,
            animated: false,
            style: {
              stroke: theme === 'dark' ? '#94a3b8' : '#64748b',
              strokeWidth: 2
            }
          }
        },
        React.createElement(Background, {
          color: themeColors.backgroundDots,
          gap: 20,
          variant: "dots"
        }),
        React.createElement(
          Controls,
          { showInteractive: false },
          opts.exportButton !== false && canExportPng
            ? React.createElement(ControlButton, {
                onClick: function() { exportPng(el, state, theme); },
                title: 'Download PNG',
                'aria-label': 'Download PNG'
              }, React.createElement('svg', {
                width: 14, height: 14, viewBox: '0 0 24 24', fill: 'none',
                stroke: 'currentColor', strokeWidth: 2.5,
                strokeLinecap: 'round', strokeLinejoin: 'round'
              },
                React.createElement('path', { key: 'stem', d: 'M12 4v11' }),
                React.createElement('path', { key: 'head', d: 'M6 10l6 6 6-6' }),
                React.createElement('path', { key: 'base', d: 'M5 20h14' })
              ))
            : null
        ),
        opts.minimap && MiniMap
          ? React.createElement(MiniMap, {
              pannable: true,
              zoomable: true,
              nodeColor: function(node) {
                return (node.data && node.data.colors && node.data.colors.border) || '#3b82f6';
              },
              nodeStrokeColor: 'none'
            })
          : null,
        opts.legend !== false && Panel
          ? legendPanel(React, Panel, theme, presentTypes, hasIndirect)
          : null
      );
    };
    
    state.container = container;
    if (ReactDOM.createRoot) {
      state.root = ReactDOM.createRoot(container);
      state.root.render(React.createElement(FlowComponent));
    } else {
      ReactDOM.render(React.createElement(FlowComponent), container);
    }
  } catch (e) {
    console.error('React Flow rendering error:', e);
    // Fallback to SVG on error
    renderSVG(el, x, width, height);
  }
}

// Removed manual helper functions - now using from bundle


// The SVG fallback builds markup via innerHTML, so labels must be escaped
// (the React path is safe: React escapes text content itself)
function escapeHtml(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Geometry mirrors the R-side layout model in layout_positions(): 44px
// header + 33px per column row, so edges anchor at the rows R assumed
// when it spaced the nodes. Width is TableNode's minWidth.
var SVG_NODE_W = 200;
var SVG_HEADER_H = 44;
var SVG_ROW_H = 33;

function svgColumnsOf(node) {
  var cols = (node.data && node.data.columns) || [];
  return Array.isArray(cols) ? cols : [cols];
}

function svgNodeHeight(node) {
  return SVG_HEADER_H + SVG_ROW_H * svgColumnsOf(node).length;
}

// Column-row anchor for an edge endpoint; header center when the handle
// isn't among the node's declared columns
function svgAnchorY(node, handle) {
  var i = svgColumnsOf(node).indexOf(handle);
  if (i === -1) {
    return node.position.y + SVG_HEADER_H / 2;
  }
  return node.position.y + SVG_HEADER_H + SVG_ROW_H * i + SVG_ROW_H / 2;
}

function svgTruncate(text, max) {
  text = String(text);
  return text.length > max ? text.slice(0, max - 1) + '…' : text;
}

function renderSVG(el, x, width, height) {
  var nodes = x.nodes || [];
  var edges = x.edges || [];
  var FONT = 'font-family="system-ui, -apple-system, sans-serif"';

  // Static rendering resolves "auto" once; no live listener
  var opts = x.options || {};
  var theme = opts.theme === 'dark' || (opts.theme === 'auto' &&
    window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
    ? 'dark'
    : 'light';
  var dark = theme === 'dark';
  var t = THEME_COLORS[theme];

  // Frame the drawing around the actual content
  var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  nodes.forEach(function(node) {
    minX = Math.min(minX, node.position.x);
    minY = Math.min(minY, node.position.y);
    maxX = Math.max(maxX, node.position.x + SVG_NODE_W);
    maxY = Math.max(maxY, node.position.y + svgNodeHeight(node));
  });
  if (!nodes.length) {
    minX = 0; minY = 0; maxX = 800; maxY = 200;
  }
  var pad = 20;
  var viewBox = (minX - pad) + ' ' + (minY - pad) + ' ' +
    (maxX - minX + 2 * pad) + ' ' + (maxY - minY + 2 * pad);
  var svgHeight = Math.max(200, (el.offsetHeight || height || 400) - 44);

  var html = '<svg width="100%" height="' + svgHeight + '" viewBox="' + viewBox + '" ' +
    'preserveAspectRatio="xMidYMid meet" ' +
    'style="background: ' + (dark ? '#141414' : '#fafafa') +
    '; border: 1px solid ' + (dark ? '#3f3f46' : '#e0e0e0') + '; display: block;">';

  // One arrowhead marker per distinct edge color, so arrows match lines
  var markerIds = {};
  var defs = '';
  edges.forEach(function(edge) {
    var stroke = (edge.style && edge.style.stroke) || '#64748b';
    if (dark) {
      stroke = darkEdgeColor(stroke);
    }
    if (!markerIds[stroke]) {
      var id = 'lineage-arrow-' + stroke.replace(/[^a-zA-Z0-9]/g, '');
      markerIds[stroke] = id;
      defs += '<marker id="' + id + '" markerWidth="8" markerHeight="8" ' +
        'refX="7" refY="3" orient="auto" markerUnits="userSpaceOnUse">' +
        '<polygon points="0 0, 8 3, 0 6" fill="' + escapeHtml(stroke) + '"/></marker>';
    }
  });
  html += '<defs>' + defs + '</defs>';

  // Edges under nodes, matching the React layering
  edges.forEach(function(edge) {
    var sourceNode = nodes.find(function(n) { return n.id === edge.source; });
    var targetNode = nodes.find(function(n) { return n.id === edge.target; });
    if (!sourceNode || !targetNode) {
      return;
    }

    var x1 = sourceNode.position.x + SVG_NODE_W;
    var y1 = svgAnchorY(sourceNode, edge.sourceHandle);
    var x2 = targetNode.position.x - 6;
    var y2 = svgAnchorY(targetNode, edge.targetHandle);
    var dx = Math.max(40, Math.abs(x2 - x1) * 0.4);

    var style = edge.style || {};
    var stroke = style.stroke || '#64748b';
    if (dark) {
      stroke = darkEdgeColor(stroke);
    }
    var strokeWidth = style.strokeWidth || 2;
    html += '<path d="M ' + x1 + ' ' + y1 +
      ' C ' + (x1 + dx) + ' ' + y1 + ', ' + (x2 - dx) + ' ' + y2 +
      ', ' + x2 + ' ' + y2 + '" fill="none" ' +
      'stroke="' + escapeHtml(stroke) + '" stroke-width="' + escapeHtml(strokeWidth) + '" ' +
      (style.strokeDasharray ? 'stroke-dasharray="' + escapeHtml(style.strokeDasharray) + '" ' : '') +
      'marker-end="url(#' + markerIds[stroke] + ')"/>';
  });

  nodes.forEach(function(node) {
    var nx = node.position.x;
    var ny = node.position.y;
    var columns = svgColumnsOf(node);
    var nodeH = svgNodeHeight(node);
    var colors = themeNodeColors(node, theme);
    if (!colors.bg) {
      colors = { bg: '#f0f7ff', border: '#3b82f6', header: '#1d4ed8' };
    }
    var label = (node.data && node.data.label) ? node.data.label : node.id;

    // Body, then header (rounded top squared off below), then rows, with
    // the border stroked last so it stays crisp over the fills
    html += '<rect x="' + nx + '" y="' + (ny + SVG_HEADER_H) + '" width="' + SVG_NODE_W +
      '" height="' + (nodeH - SVG_HEADER_H) + '" fill="' + escapeHtml(colors.bg) + '"/>';
    html += '<rect x="' + nx + '" y="' + ny + '" width="' + SVG_NODE_W +
      '" height="' + SVG_HEADER_H + '" rx="8" fill="' + escapeHtml(colors.header) + '"/>';
    html += '<rect x="' + nx + '" y="' + (ny + SVG_HEADER_H / 2) + '" width="' + SVG_NODE_W +
      '" height="' + (SVG_HEADER_H / 2) + '" fill="' + escapeHtml(colors.header) + '"/>';
    html += '<text x="' + (nx + 14) + '" y="' + (ny + SVG_HEADER_H / 2) + '" ' +
      'dominant-baseline="central" ' + FONT + ' font-size="14" font-weight="600" ' +
      'fill="#ffffff">' + escapeHtml(svgTruncate(label, 22)) + '</text>';

    columns.forEach(function(column, i) {
      var rowY = ny + SVG_HEADER_H + SVG_ROW_H * i;
      var centerY = rowY + SVG_ROW_H / 2;
      if (i > 0) {
        html += '<line x1="' + nx + '" y1="' + rowY + '" x2="' + (nx + SVG_NODE_W) +
          '" y2="' + rowY + '" stroke="' + (colors.rowBorder || t.rowBorder) + '" stroke-width="1"/>';
      }
      html += '<text x="' + (nx + 14) + '" y="' + centerY + '" ' +
        'dominant-baseline="central" ' + FONT + ' font-size="13" font-weight="500" ' +
        'fill="' + (colors.text || t.text) + '">' + escapeHtml(svgTruncate(column, 24)) + '</text>';
      // Connection dots where the interactive handles would sit
      html += '<circle cx="' + nx + '" cy="' + centerY + '" r="4" ' +
        'fill="' + escapeHtml(colors.border) + '" stroke="' + (colors.nodeBg || 'white') + '" stroke-width="1.5"/>';
      html += '<circle cx="' + (nx + SVG_NODE_W) + '" cy="' + centerY + '" r="4" ' +
        'fill="' + escapeHtml(colors.border) + '" stroke="' + (colors.nodeBg || 'white') + '" stroke-width="1.5"/>';
    });

    html += '<rect x="' + nx + '" y="' + ny + '" width="' + SVG_NODE_W +
      '" height="' + nodeH + '" rx="8" fill="none" ' +
      'stroke="' + escapeHtml(colors.border) + '" stroke-width="2"/>';
  });

  html += '</svg>';

  html += '<div style="margin-top: 10px; padding: 8px 12px; background: ' +
    (dark ? '#27272a' : '#f0f0f0') + '; ';
  html += 'border-radius: 4px; font-size: 12px; font-family: system-ui, sans-serif; color: ' +
    (dark ? '#a1a1aa' : '#666') + ';">';
  html += 'Column lineage (static SVG) | Tables: ' + nodes.length + ' | Edges: ' + edges.length;
  html += '</div>';

  el.innerHTML = html;
}
