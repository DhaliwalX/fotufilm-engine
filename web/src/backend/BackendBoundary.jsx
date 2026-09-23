import { Component } from "react";

export function BackendFailure({ error }) {
  return (
    <main className="empty-canvas" role="alert">
      <h1>Unable to start Fotufilm</h1>
      <p>{error.message}</p>
    </main>
  );
}

// A host factory can fail before the editor's async error handlers are mounted.
export class BackendBoundary extends Component {
  state = { error: null };
  static getDerivedStateFromError(error) {
    return { error };
  }
  render() {
    return this.state.error ? (
      <BackendFailure error={this.state.error} />
    ) : (
      this.props.children
    );
  }
}
