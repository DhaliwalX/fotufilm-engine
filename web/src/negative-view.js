// Show Negative, as the Mac app's View menu has it: the canvas develops the film's negative in
// place of the edit's output, and nothing about the edit changes. A reversal film has no negative
// to show, no film has none, and a negative already chosen as the medium needs no switch.
export const NEGATIVE_MEDIUM = "negative";

export function canShowNegative(edit, stock) {
  if (!edit?.stock || !stock?.media?.some(({ id }) => id === NEGATIVE_MEDIUM)) return false;
  return (edit.medium || stock.defaultMedium) !== NEGATIVE_MEDIUM;
}

/** The edit the canvas develops while the negative is shown. */
export function negativeViewEdit(edit, stock, shown) {
  return shown && canShowNegative(edit, stock) ? { ...edit, medium: NEGATIVE_MEDIUM } : edit;
}
