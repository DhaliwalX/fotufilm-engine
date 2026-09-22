import "./fotufilm-brand.css";
import wordmark from "../assets/fotufilm-wordmark.svg";

export default function FotufilmBrand({ compact = false, className = "" }) {
  return (
    <div
      className={`fotufilm-brand ${compact ? "fotufilm-brand-compact" : ""} ${className}`}
      role="img"
      aria-label="Fotufilm"
    >
      <img
        className="fotufilm-logo"
        src={`${import.meta.env.BASE_URL}app-icon.png`}
        alt=""
        width="32"
        height="32"
      />
      <img
        className="fotufilm-wordmark"
        src={wordmark}
        alt=""
        width="100"
        height="20"
      />
    </div>
  );
}
