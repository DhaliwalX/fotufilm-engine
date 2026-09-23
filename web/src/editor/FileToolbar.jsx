import FotufilmBrand from "./FotufilmBrand.jsx";
import ImportMenu from "./ImportMenu.jsx";

export default function FileToolbar() {
  return (
    <div className="toolbar-leading">
      <FotufilmBrand compact className="toolbar-brand" />
      <ImportMenu />
    </div>
  );
}
