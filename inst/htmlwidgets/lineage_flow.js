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
  // Older cached bundles don't export LineageEdge; fall back to smoothstep
  var defaultEdgeType = LineageEdge ? 'lineage' : 'smoothstep';

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

      var coneInfo = useMemo(function() {
        if (!selectedColumn) {
          return null;
        }
        return computeCone(adjacency, selectedColumn);
      }, [selectedColumn]);

      // Update nodes to inject the callbacks and per-node cone state
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
              onColumnHover: onColumnHover,
              onColumnClick: onColumnClick,
              dimmed: dimmed,
              dimmedColumns: dimmedColumns,
              selectedColumn: selected
            })
          });
        });
      }, [nodes, onColumnHover, onColumnClick, coneInfo, selectedColumn]);

      // Update edges from the traced cone and the hovered handle. Cone
      // dimming wins: hovering never resurrects an edge outside the cone,
      // and in-cone edges stay at full strength unless hover-highlighted.
      var styledEdges = useMemo(function() {
        if (!hoveredHandle && !coneInfo) {
          return edges;
        }

        return edges.map(function(edge) {
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
              style: Object.assign({}, edge.style, { stroke: '#f59e0b', strokeWidth: 3 })
            });
          }
          if (coneInfo) {
            return edge;
          }
          return Object.assign({}, edge, {
            animated: false,
            style: Object.assign({}, edge.style, { stroke: '#d1d5db', strokeWidth: 2, opacity: 0.3 })
          });
        });
      }, [edges, hoveredHandle, coneInfo]);
      
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
            style: { stroke: '#64748b', strokeWidth: 2 }
          }
        },
        React.createElement(Background, { 
          color: "#d1d5db", 
          gap: 20,
          variant: "dots"
        }),
        React.createElement(Controls, { showInteractive: false })
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
    'style="background: #fafafa; border: 1px solid #e0e0e0; display: block;">';

  // One arrowhead marker per distinct edge color, so arrows match lines
  var markerIds = {};
  var defs = '';
  edges.forEach(function(edge) {
    var stroke = (edge.style && edge.style.stroke) || '#64748b';
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
    var colors = (node.data && node.data.colors) ||
      { bg: '#f0f7ff', border: '#3b82f6', header: '#1d4ed8' };
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
          '" y2="' + rowY + '" stroke="#e5e7eb" stroke-width="1"/>';
      }
      html += '<text x="' + (nx + 14) + '" y="' + centerY + '" ' +
        'dominant-baseline="central" ' + FONT + ' font-size="13" font-weight="500" ' +
        'fill="#1f2937">' + escapeHtml(svgTruncate(column, 24)) + '</text>';
      // Connection dots where the interactive handles would sit
      html += '<circle cx="' + nx + '" cy="' + centerY + '" r="4" ' +
        'fill="' + escapeHtml(colors.border) + '" stroke="#ffffff" stroke-width="1.5"/>';
      html += '<circle cx="' + (nx + SVG_NODE_W) + '" cy="' + centerY + '" r="4" ' +
        'fill="' + escapeHtml(colors.border) + '" stroke="#ffffff" stroke-width="1.5"/>';
    });

    html += '<rect x="' + nx + '" y="' + ny + '" width="' + SVG_NODE_W +
      '" height="' + nodeH + '" rx="8" fill="none" ' +
      'stroke="' + escapeHtml(colors.border) + '" stroke-width="2"/>';
  });

  html += '</svg>';

  html += '<div style="margin-top: 10px; padding: 8px 12px; background: #f0f0f0; ';
  html += 'border-radius: 4px; font-size: 12px; font-family: system-ui, sans-serif; color: #666;">';
  html += 'Column lineage (static SVG) | Tables: ' + nodes.length + ' | Edges: ' + edges.length;
  html += '</div>';

  el.innerHTML = html;
}
