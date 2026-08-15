type ProfileAvatarProps = {
  name: string;
  avatarUrl?: string | null;
  className?: string;
};

function initials(name: string) {
  return (name.trim() || "V")
    .split(/\s+/)
    .slice(0, 2)
    .map((part) => part[0])
    .join("")
    .toUpperCase();
}

export function ProfileAvatar({ name, avatarUrl, className = "profile-avatar" }: ProfileAvatarProps) {
  return (
    <span
      className={`${className}${avatarUrl ? " has-image" : ""}`}
      style={avatarUrl ? { background: `url(${JSON.stringify(avatarUrl)}) center / cover no-repeat` } : undefined}
      aria-label={`Аватар: ${name}`}
    >
      {!avatarUrl && initials(name)}
    </span>
  );
}
