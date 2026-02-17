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
  addEdge
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
    addEdge
  };
}
