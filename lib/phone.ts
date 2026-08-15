export function normalizeRussianPhone(value: string) {
  let digits = value.replace(/\D/g, "");

  if (digits.length === 10) digits = `7${digits}`;
  if (digits.length === 11 && digits.startsWith("8")) {
    digits = `7${digits.slice(1)}`;
  }

  return digits.length === 11 && digits.startsWith("7")
    ? `+${digits}`
    : null;
}

export function formatRussianPhone(value: string) {
  let digits = value.replace(/\D/g, "");

  if (digits.startsWith("8")) digits = `7${digits.slice(1)}`;
  if (!digits.startsWith("7")) digits = `7${digits}`;
  digits = digits.slice(0, 11);

  const national = digits.slice(1);
  let result = "+7";
  if (national.length > 0) result += ` (${national.slice(0, 3)}`;
  if (national.length >= 3) result += ")";
  if (national.length > 3) result += ` ${national.slice(3, 6)}`;
  if (national.length > 6) result += ` ${national.slice(6, 8)}`;
  if (national.length > 8) result += ` ${national.slice(8, 10)}`;
  return result;
}
