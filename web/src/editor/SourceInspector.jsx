import {
  Disclosure,
  DisclosureTitle,
  DisclosurePanel,
} from "@react-spectrum/s2/Disclosure";
import ProfileFields from "./ProfileFields.jsx";
import { useEditor } from "./EditorContext.jsx";

const stops = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 });

// How much of an HDR photo's recorded range above white reaches the film, and how strongly it is
// eased into the film's latitude. Only a photo that declares headroom has any to keep.
export default function SourceInspector() {
  const { active } = useEditor();
  const headroom = active?.image?.hdr?.headroom;
  if (!(headroom > 1) || active.image.video) return null;
  return (
    <Disclosure
      defaultExpanded={true}
      size={"S"}
      isQuiet
      UNSAFE_className={"inspector-section"}
    >
      <DisclosureTitle>{"HDR Highlights"}</DisclosureTitle>
      <DisclosurePanel>
        <div className="control-stack">
          <ProfileFields fields={["hdrRange", "hdrRollOff"]} />
          <p className="medium-detail">
            {`${stops.format(Math.log2(headroom))} stops above white recorded`}
          </p>
        </div>
      </DisclosurePanel>
    </Disclosure>
  );
}
