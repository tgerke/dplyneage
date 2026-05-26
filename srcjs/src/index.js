import React from 'react';
import ReactDOM from 'react-dom';
import { 
  ReactFlow, 
  Background, 
  Controls,
  Handle,
  Position,
  applyNodeChanges,
  applyEdgeChanges,
  addEdge
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';

// Custom Table Node Component for column-level lineage
const TableNode = ({ data, isConnectable, id }) => {
  // Ensure columns is always an array (handle R's single-element vectors)
  const columns = Array.isArray(data.columns) 
    ? data.columns 
    : (data.columns ? [data.columns] : []);
  const colors = data.colors || { bg: '#f0f7ff', border: '#3b82f6', header: '#1d4ed8' };
  
  // Get the hover callback from data if available
  const onColumnHover = data.onColumnHover || (() => {});
  
  return (
    <div style={{
      background: 'white',
      border: `2px solid ${colors.border}`,
      borderRadius: '8px',
      minWidth: '200px',
      fontSize: '13px',
      fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
      boxShadow: '0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06)'
    }}>
      {/* Table Header */}
      <div style={{
        background: colors.header,
        color: 'white',
        padding: '10px 14px',
        fontWeight: 600,
        fontSize: '14px',
        borderTopLeftRadius: '6px',
        borderTopRightRadius: '6px',
        letterSpacing: '0.01em'
      }}>
        {data.label}
      </div>
      
      {/* Column List */}
      <div style={{ background: colors.bg }}>
        {columns.map((column, index) => (
          <div key={column} style={{
            padding: '8px 14px',
            borderBottom: index < columns.length - 1 ? '1px solid #e5e7eb' : 'none',
            display: 'flex',
            alignItems: 'center',
            position: 'relative',
            transition: 'background 0.15s ease'
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.background = '#ffffff';
            onColumnHover(id, column);
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.background = 'transparent';
            onColumnHover(null, null);
          }}
          >
            {/* Left handle for incoming connections */}
            <Handle
              type="target"
              position={Position.Left}
              id={column}
              style={{
                background: colors.border,
                width: '10px',
                height: '10px',
                border: '2px solid white',
                left: '-6px'
              }}
              isConnectable={isConnectable}
            />
            
            {/* Column name with icon */}
            <span style={{
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
              color: '#1f2937',
              fontWeight: 500
            }}>
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <rect x="1" y="1" width="10" height="10" rx="2" stroke={colors.border} strokeWidth="1.5"/>
                <path d="M4 4h4M4 6h4M4 8h2" stroke={colors.border} strokeWidth="1.5" strokeLinecap="round"/>
              </svg>
              {column}
            </span>
            
            {/* Right handle for outgoing connections */}
            <Handle
              type="source"
              position={Position.Right}
              id={column}
              style={{
                background: colors.border,
                width: '10px',
                height: '10px',
                border: '2px solid white',
                right: '-6px'
              }}
              isConnectable={isConnectable}
            />
          </div>
        ))}
      </div>
    </div>
  );
};

// Export everything that the R htmlwidget will need
export {
  React,
  ReactDOM,
  ReactFlow,
  Background,
  Controls,
  Handle,
  Position,
  applyNodeChanges,
  applyEdgeChanges,
  addEdge,
  TableNode
};

// Also make available on window for htmlwidgets
if (typeof window !== 'undefined') {
  window.ReactFlowBundle = {
    React,
    ReactDOM,
    ReactFlow,
    Background,
    Controls,
    Handle,
    Position,
    applyNodeChanges,
    applyEdgeChanges,
    addEdge,
    TableNode
  };
}
