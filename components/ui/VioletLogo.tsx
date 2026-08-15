import Link from "next/link";

type VioletLogoProps = {
  compact?: boolean;
  href?: string;
  className?: string;
};

export function VioletLogo({ compact = false, href = "/messenger", className = "" }: VioletLogoProps) {
  return (
    <Link className={`violet-logo ${compact ? "compact" : ""} ${className}`} href={href} aria-label="Violet">
      <svg aria-hidden="true" viewBox="0 0 64 64">
        <defs>
          <linearGradient id="violet-logo-gradient" x1="8" y1="6" x2="56" y2="58" gradientUnits="userSpaceOnUse">
            <stop stopColor="#a487ff" />
            <stop offset="0.48" stopColor="#7042f5" />
            <stop offset="1" stopColor="#4b1fcf" />
          </linearGradient>
        </defs>
        <path d="M27.6 8.3c5.1-3.4 11.9-3 16.5 1.1l10.5 9.3c6.5 5.7 6.2 15.9-.5 21.3L30.8 58.1C21.6 65.2 8.2 58.7 8.5 47L9 24.2c.1-4.6 2.5-8.8 6.3-11.3l12.3-4.6Zm-1.4 15.5-.4 18.7 18-14.2-9.2-8.1-8.4 3.6Z" fill="url(#violet-logo-gradient)" />
      </svg>
      {!compact && <span>Violet</span>}
    </Link>
  );
}
