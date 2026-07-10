HTMLWidgets.widget({
  name: 'lineage_flow',
  type: 'output',
  factory: function(el, width, height) {
    return {
      renderValue: function(x) {
        var nodes = x.nodes || [];
        var edges = x.edges || [];
        
        // Check if React Flow bundle is available
        if (typeof window.ReactFlowBundle !== 'undefined') {
          // Use React Flow for interactive visualization
          renderReactFlow(el, x, width, height);
        } else {
          // Fallback to SVG visualization
          renderSVG(el, x, width, height);
        }
      },
      resize: function(width, height) {
        // Handle resize
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

function renderReactFlow(el, x, width, height) {
  var React = window.ReactFlowBundle.React;
  var ReactDOM = window.ReactFlowBundle.ReactDOM;
  var ReactFlow = window.ReactFlowBundle.ReactFlow;
  var Background = window.ReactFlowBundle.Background;
  var Controls = window.ReactFlowBundle.Controls;
  var applyNodeChanges = window.ReactFlowBundle.applyNodeChanges;
  var applyEdgeChanges = window.ReactFlowBundle.applyEdgeChanges;
  var addEdge = window.ReactFlowBundle.addEdge;
  var TableNode = window.ReactFlowBundle.TableNode;
  var LineageEdge = window.ReactFlowBundle.LineageEdge;
  // Older cached bundles don't export LineageEdge; fall back to smoothstep
  var defaultEdgeType = LineageEdge ? 'lineage' : 'smoothstep';

  el.style.width = '100%';
  el.style.height = height || '600px';
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
      
      // Callback for when a column is hovered
      var onColumnHover = useCallback(function(nodeId, handleId) {
        if (nodeId && handleId) {
          setHoveredHandle({ nodeId: nodeId, handleId: handleId });
        } else {
          setHoveredHandle(null);
        }
      }, []);
      
      // Update nodes to inject the hover callback
      var nodesWithCallback = useMemo(function() {
        return nodes.map(function(node) {
          return Object.assign({}, node, {
            data: Object.assign({}, node.data, {
              onColumnHover: onColumnHover
            })
          });
        });
      }, [nodes, onColumnHover]);
      
      // Update edges based on hovered handle
      var styledEdges = useMemo(function() {
        if (!hoveredHandle) {
          return edges;
        }
        
        return edges.map(function(edge) {
          // Check if this edge is connected to the hovered handle
          var isConnected = (
            (edge.source === hoveredHandle.nodeId && edge.sourceHandle === hoveredHandle.handleId) ||
            (edge.target === hoveredHandle.nodeId && edge.targetHandle === hoveredHandle.handleId)
          );
          
          if (isConnected) {
            return Object.assign({}, edge, {
              animated: true,
              style: { stroke: '#f59e0b', strokeWidth: 3 }
            });
          } else {
            return Object.assign({}, edge, {
              animated: false,
              style: { stroke: '#d1d5db', strokeWidth: 2, opacity: 0.3 }
            });
          }
        });
      }, [edges, hoveredHandle]);
      
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
      
      // Handle new edge connections
      var onConnect = useCallback(function(connection) {
        setEdges(function(eds) {
          return addEdge(connection, eds);
        });
      }, []);
      
      return React.createElement(
        ReactFlow,
        {
          nodes: nodesWithCallback,
          edges: styledEdges,
          onNodesChange: onNodesChange,
          onEdgesChange: onEdgesChange,
          onConnect: onConnect,
          nodeTypes: nodeTypes,
          edgeTypes: edgeTypes,
          fitView: true,
          fitViewOptions: { padding: 0.2 },
          minZoom: 0.1,
          maxZoom: 4,
          nodesDraggable: true,
          nodesConnectable: true,
          elementsSelectable: true,
          snapToGrid: true,
          snapGrid: [15, 15],
          connectionLineStyle: { stroke: '#64748b', strokeWidth: 2 },
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
    
    if (ReactDOM.createRoot) {
      var root = ReactDOM.createRoot(container);
      root.render(React.createElement(FlowComponent));
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

function renderSVG(el, x, width, height) {
  var nodes = x.nodes || [];
  var edges = x.edges || [];
  
  var svgWidth = width || 800;
  var svgHeight = height || 400;
  
  var html = '<svg width="' + svgWidth + '" height="' + svgHeight + '" style="background: #fafafa; border: 1px solid #e0e0e0;">';
  
  html += '<defs><marker id="arrowhead" markerWidth="10" markerHeight="10" refX="9" refY="3" orient="auto">';
  html += '<polygon points="0 0, 10 3, 0 6" fill="#0088ff"/>';
  html += '</marker></defs>';
  
  edges.forEach(function(edge) {
    var sourceNode = nodes.find(function(n) { return n.id === edge.source; });
    var targetNode = nodes.find(function(n) { return n.id === edge.target; });
    
    if (sourceNode && targetNode) {
      var x1 = sourceNode.position.x + 75;
      var y1 = sourceNode.position.y + 30;
      var x2 = targetNode.position.x + 75;
      var y2 = targetNode.position.y + 30;
      
      html += '<line x1="' + x1 + '" y1="' + y1 + '" x2="' + x2 + '" y2="' + y2 + '" ';
      html += 'stroke="#0088ff" stroke-width="2" marker-end="url(#arrowhead)"/>';
    }
  });
  
  nodes.forEach(function(node) {
    var x = node.position.x;
    var y = node.position.y;
    var label = (node.data && node.data.label) ? node.data.label : node.id;
    
    html += '<rect x="' + x + '" y="' + y + '" width="150" height="60" ';
    html += 'fill="white" stroke="#1a192b" stroke-width="2" rx="8"/>';
    
    html += '<text x="' + (x + 75) + '" y="' + (y + 35) + '" ';
    html += 'text-anchor="middle" font-family="system-ui, -apple-system, sans-serif" ';
    html += 'font-size="14" font-weight="500" fill="#1a192b">' + escapeHtml(label) + '</text>';
  });
  
  html += '</svg>';
  
  html += '<div style="margin-top: 10px; padding: 8px 12px; background: #f0f0f0; ';
  html += 'border-radius: 4px; font-size: 12px; font-family: system-ui, sans-serif; color: #666;">';
  html += 'Column Lineage Flow (SVG) | Nodes: ' + nodes.length + ' | Edges: ' + edges.length;
  html += '</div>';
  
  el.innerHTML = html;
}
