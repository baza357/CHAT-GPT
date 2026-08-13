import "./globals.css";

export const metadata = {
  title: "Messenger",
  description: "MVP мессенджера на Next.js + Supabase"
};

export default function RootLayout({
  children
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ru">
      <body>{children}</body>
    </html>
  );
}
