import "./globals.css";
import type { Metadata, Viewport } from "next";
import { PwaRegistration } from "@/components/pwa/PwaRegistration";
import { InternetCallProvider } from "@/components/calls/InternetCallProvider";
import { NotificationProvider } from "@/components/notifications/NotificationProvider";

export const metadata: Metadata = {
  title: { default: "МастерPRO", template: "%s — МастерPRO" },
  description: "МастерPRO — личные сообщения, контакты и звонки",
  manifest: "/manifest.webmanifest",
  icons: { icon: "/icon.svg", apple: "/icon.svg" },
  appleWebApp: { capable: true, statusBarStyle: "default", title: "МастерPRO" },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#7047f5",
};

export default function RootLayout({
  children
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ru">
      <body>
        <NotificationProvider>
          <InternetCallProvider>{children}</InternetCallProvider>
        </NotificationProvider>
        <PwaRegistration />
      </body>
    </html>
  );
}
