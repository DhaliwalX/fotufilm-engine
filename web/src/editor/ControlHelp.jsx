import { ContextualHelp } from "@react-spectrum/s2/ContextualHelp";
import { Content } from "@react-spectrum/s2/Dialog";
import { EDITOR_CONTROLS } from "../generated/controls.js";

/** The catalogue's help for a control field, if it is one. */
export const controlDetail = (field) =>
  EDITOR_CONTROLS.find((control) => control.field === field)?.detail;

/**
 * The help button beside a control's name, as the Mac app's inspector rows carry one: the
 * catalogue's description of the control in a popover. Nothing where there is no description.
 */
export function controlHelp(label, detail) {
  if (!detail) return undefined;
  return (
    <ContextualHelp aria-label={`Help for ${label}`} placement="bottom start">
      <Content>{detail}</Content>
    </ContextualHelp>
  );
}

/** A switch or other labelled control with the help button after it. */
export function WithHelp({ label, detail, children }) {
  const help = controlHelp(label, detail);
  if (!help) return children;
  return (
    <div className="control-with-help">
      {children}
      {help}
    </div>
  );
}
