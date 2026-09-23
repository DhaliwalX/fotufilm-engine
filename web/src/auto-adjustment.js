export const autoWindowChanged = (before, after) =>
  before.stock !== after.stock ||
  (before.profile.printCorrection ?? 0) !==
    (after.profile.printCorrection ?? 0);
export const autoToneChanged = (before, after) =>
  ["ev", "highlights", "shadows"].some(
    (key) => before.params[key] !== after.params[key],
  );

// Own only the transient Auto mode. The solved values use ordinary edit history.
// A generation and abort signal prevent old measurements from overwriting edits.
export class AutoAdjustmentController {
  constructor({
    snapshot,
    apply,
    onState,
    onError,
    solve,
  }) {
    Object.assign(this, { snapshot, apply, onState, onError, solve });
    this.state = { active: false, busy: false, status: null };
    this.generation = 0;
  }
  publish(value) {
    this.state = value;
    this.onState(value);
  }
  cancel(notify = true) {
    this.generation++;
    this.abort?.abort();
    this.abort = null;
    if (notify) this.publish({ active: false, busy: false, status: null });
  }
  toggle() {
    if (this.state.active) this.cancel();
    else this.run(this.snapshot().history.present);
  }
  changed(action, before, after) {
    if (action.restoring) {
      this.cancel();
      return;
    }
    if (action.type === "end" || before === after) return;
    if (
      action.type !== "edit" ||
      autoToneChanged(before.present, after.present)
    ) {
      this.cancel();
    } else if (
      this.state.active &&
      autoWindowChanged(before.present, after.present)
    ) {
      this.run(after.present);
    } else if (this.state.busy) this.cancel();
  }
  async run(edit) {
    const { image, session, disabled } = this.snapshot();
    if (!image || image.video || !session || disabled) return;
    this.cancel(false);
    const generation = this.generation,
      controller = new AbortController();
    this.abort = controller;
    const current = () =>
      generation === this.generation &&
      this.snapshot().image === image &&
      !this.snapshot().disabled;
    this.publish({
      active: true,
      busy: true,
      status: "Measuring the photograph",
    });
    try {
      const params = await this.solve({
        image,
        session,
        edit,
        signal: controller.signal,
        onProgress: (status) => {
          if (current()) this.publish({ active: true, busy: true, status });
        },
      });
      if (!current()) return;
      this.apply(params);
      this.publish({ active: true, busy: false, status: null });
    } catch (error) {
      if (!current()) return;
      this.cancel();
      if (error.name !== "AbortError") this.onError(error.message);
    }
  }
}
