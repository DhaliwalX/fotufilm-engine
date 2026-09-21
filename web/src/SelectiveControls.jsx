import { Button } from '@astryxdesign/core/Button'
import { Selector } from '@astryxdesign/core/Selector'
import { Switch } from '@astryxdesign/core/Switch'
import { SELECTION } from './generated/controls.js'
import { SLIDERS } from './editor-state.js'
import { newSelection, selectionDevelop, selectionKeys } from './selective.js'
import { Adjustment, Section } from './EditorControls.jsx'

export default function SelectiveControls({
  edit,
  patch,
  endEdit,
  sampling,
  setSampling,
  showMask,
  setShowMask,
  canSample,
  disabled,
}) {
  const selection = edit.selective || newSelection(edit)
  const change = (value, group) =>
    patch({ selective: { ...selection, ...value } }, group)
  return (
    <>
      <Section title={SELECTION.section}>
        <Selector
          label={SELECTION.kind}
          value={selection.kind}
          options={SELECTION.choices}
          size="sm"
          width="100%"
          isDisabled={disabled}
          onChange={(kind) => change({ kind })}
        />
        <Button
          label={sampling ? SELECTION.sampling : SELECTION.sample}
          variant="secondary"
          size="sm"
          isDisabled={disabled || !canSample}
          onClick={() => setSampling(!sampling)}
        />
        {SELECTION.sliders.map((slider) => (
          <Adjustment
            key={slider.key}
            disabled={disabled}
            slider={slider}
            value={selection[slider.key]}
            onChange={(value) =>
              change({ [slider.key]: value }, `selective-${slider.key}`)
            }
            onEnd={endEdit}
          />
        ))}
        <Switch
          label={SELECTION.mask}
          value={showMask}
          isDisabled={disabled || !selection.sample}
          size="sm"
          onChange={setShowMask}
        />
        <Button
          label={SELECTION.clear}
          variant="secondary"
          size="sm"
          isDisabled={disabled || !edit.selective}
          onClick={() => {
            patch({ selective: null })
            setSampling(false)
            setShowMask(false)
          }}
        />
        <p className="medium-detail">
          Sample the photo to select similar colors or brightness, then adjust
          the selection.
        </p>
      </Section>
      <Section title="Selection Light">
        {SLIDERS.filter(
          (s) => selectionKeys.includes(s.key) && !s.key.startsWith('grade'),
        ).map((slider) => (
          <Adjustment
            key={slider.key}
            disabled={disabled}
            slider={slider}
            value={selection.params[slider.key]}
            onChange={(value) =>
              change(
                { params: { ...selection.params, [slider.key]: value } },
                `selective-${slider.key}`,
              )
            }
            onEnd={endEdit}
          />
        ))}
        <Switch
          label="Regional"
          value={selection.localTone}
          isDisabled={disabled}
          size="sm"
          onChange={(localTone) => change({ localTone })}
        />
        <Button
          label={SELECTION.match}
          isDisabled={disabled}
          variant="secondary"
          size="sm"
          onClick={() => change(selectionDevelop(edit))}
        />
      </Section>
    </>
  )
}
