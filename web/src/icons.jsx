import { Film } from 'reicon-react/icons/Film'
import { GalleryAdd } from 'reicon-react/icons/GalleryAdd'
import { Minus } from 'reicon-react/icons/Minus'
import { Add } from 'reicon-react/icons/Add'
import { Fullscreen } from 'reicon-react/icons/Fullscreen'
import { Undo } from 'reicon-react/icons/Undo'
import { Redo } from 'reicon-react/icons/Redo'
import { Refresh } from 'reicon-react/icons/Refresh'
import { Export } from 'reicon-react/icons/Export'
import { ChartBar } from 'reicon-react/icons/ChartBar'
import { Setting4 } from 'reicon-react/icons/Setting4'
import { Crop2 } from 'reicon-react/icons/Crop2'
import { Mask3 } from 'reicon-react/icons/Mask3'
import { SidebarLeft } from 'reicon-react/icons/SidebarLeft'
import { SidebarRight } from 'reicon-react/icons/SidebarRight'
import { More } from 'reicon-react/icons/More'
import { X } from 'reicon-react/icons/X'
import { Search2 } from 'reicon-react/icons/Search2'
import { RotateLeft } from 'reicon-react/icons/RotateLeft'
import { FlipH } from 'reicon-react/icons/FlipH'
import { Check } from 'reicon-react/icons/Check'
import { ChevronDown } from 'reicon-react/icons/ChevronDown'
import { ChevronLeft } from 'reicon-react/icons/ChevronLeft'
import { ChevronRight } from 'reicon-react/icons/ChevronRight'
import { CheckCircle } from 'reicon-react/icons/CheckCircle'
import { CloseCircle } from 'reicon-react/icons/CloseCircle'
import { Danger } from 'reicon-react/icons/Danger'
import { InfoCircle } from 'reicon-react/icons/InfoCircle'

const icons = {
  film: Film,
  open: GalleryAdd,
  minus: Minus,
  plus: Add,
  fit: Fullscreen,
  undo: Undo,
  redo: Redo,
  reset: Refresh,
  export: Export,
  histogram: ChartBar,
  adjustments: Setting4,
  crop: Crop2,
  compare: Mask3,
  sidebar: SidebarLeft,
  inspector: SidebarRight,
  more: More,
  close: X,
  search: Search2,
  rotate: RotateLeft,
  flip: FlipH,
  check: Check,
  chevronDown: ChevronDown,
  chevronLeft: ChevronLeft,
  chevronRight: ChevronRight,
  success: CheckCircle,
  error: CloseCircle,
  warning: Danger,
  info: InfoCircle,
}

export function Icon({ name, size = 18, ...props }) {
  const Component = icons[name] || Film
  return (
    <Component
      size={size}
      weight="Outline"
      color="currentColor"
      aria-hidden="true"
      focusable="false"
      {...props}
    />
  )
}

// Match the editor icons in Astryx selectors, inputs and their status messages.
export const controlIcons = Object.fromEntries(
  [
    'close',
    'chevronDown',
    'chevronLeft',
    'chevronRight',
    'check',
    'success',
    'error',
    'warning',
    'info',
    'search',
  ].map((name) => [name, <Icon key={name} name={name} size="1em" />]),
)
