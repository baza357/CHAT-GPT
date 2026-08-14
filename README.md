# Messenger — Next.js + Supabase

Веб-мессенджер на Next.js 16, React 19, TypeScript и Supabase.

Сейчас реализованы:

- регистрация с подтверждением email;
- вход, выход и восстановление пароля;
- cookie-based сессия с автоматическим обновлением;
- защищённые маршруты `/messenger` и `/settings`;
- автоматически создаваемые профили с RLS;
- редактирование профиля и смена пароля;
- личные диалоги и Supabase Realtime из исходного MVP;
- адаптивный интерфейс.

## 1. Установка

```powershell
npm.cmd install
```

## 2. Переменные окружения

Скопируйте `.env.example` в `.env.local` и вставьте значения из Supabase:

```env
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_your_key
```

Ключи находятся в Supabase Dashboard → проект → **Connect**. Используйте
publishable key. `service_role`/secret key клиентскому приложению не нужен.

## 3. База данных

Для нового пустого проекта выполните в Supabase SQL Editor файл:

```text
supabase/database.sql
```

Если исходная MVP-схема уже была выполнена, примените только новую миграцию:

```text
supabase/migrations/20260814223354_auth_profiles.sql
```

Миграция добавляет поля профиля, индексы, RLS и безопасный trigger создания
профиля. SQL можно запускать целиком через SQL Editor → New query → Run.

## 4. URL авторизации

В Supabase Dashboard откройте **Authentication → URL Configuration**.

Для локальной разработки укажите:

```text
Site URL: http://localhost:3000
Redirect URLs: http://localhost:3000/auth/callback
```

После публикации добавьте такой же callback для рабочего домена, например:

```text
https://your-domain.example/auth/callback
```

Это необходимо для подтверждения email и восстановления пароля.

## 5. Запуск и проверки

```powershell
npm.cmd run dev
npm.cmd run typecheck
npm.cmd run lint
npm.cmd run build
```

Откройте [http://localhost:3000](http://localhost:3000).

## Проверка основного сценария

1. Создайте первый аккаунт на `/register` и подтвердите email.
2. Создайте второй аккаунт в другом браузере или приватном окне.
3. Войдите в оба аккаунта.
4. Выберите второго пользователя в `/messenger`.
5. Отправьте сообщение — оно должно появиться во втором окне без перезагрузки.
