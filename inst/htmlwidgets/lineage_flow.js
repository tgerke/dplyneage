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
  
  el.style.width = '100%';
  el.style.height = height || '600px';
  el.innerHTML = '<div id="reactflow-container" style="width: 100%; height: 100%;"></div>';
  
  var container = el.querySelector('#reactflow-container');
  
  // Define custom node types
  var nodeTypes = {
    tableNode: TableNode
  };
  
  // Ensure nodes are connectable with default styling
  var initialNodes = (x.nodes || []).map(function(node) {
    return Object.assign({}, node, {
      type: node.type || 'default',
      draggable: true
    });
  });
  
  var initialEdges = (x.edges || []).map(function(edge) {
    return Object.assign({}, edge, {
      type: edge.type || 'smoothstep',
      animated: edge.animated || false
    });
  });
  
  try {
    var FlowComponent = function() {
      var useState = React.useState;
      var useCallback = React.useCallback;
      
      var nodesState = useState(initialNodes);
      var nodes = nodesState[0];
      var setNodes = nodesState[1];
      
      var edgesState = useState(initialEdges);
      var edges = edgesState[0];
      var setEdges = edgesState[1];
      
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
          nodes: nodes,
          edges: edges,
          onNodesChange: onNodesChange,
          onEdgesChange: onEdgesChange,
          onConnect: onConnect,
          nodeTypes: nodeTypes,
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
            type: 'smoothstep',
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
    html += 'font-size="14" font-weight="500" fill="#1a192b">' + label + '</text>';
  });
  
  html += '</svg>';
  
  html += '<div style="margin-top: 10px; padding: 8px 12px; background: #f0f0f0; ';
  html += 'border-radius: 4px; font-size: 12px; font-family: system-ui, sans-serif; color: #666;">';
  html += 'Column Lineage Flow (SVG) | Nodes: ' + nodes.length + ' | Edges: ' + edges.length;
  html += '</div>';
  
  el.innerHTML = html;
}
