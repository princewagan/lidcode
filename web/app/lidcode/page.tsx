/**
 * app/lidcode/page.tsx
 *
 * Permanent redirect to the site root.
 *
 * The LidCode dashboard moved to / in August 2026. This file exists so that
 * any bookmark or shared link that still points to /lidcode lands correctly
 * instead of returning 404. The redirect is permanent (308) so browsers and
 * crawlers update their records.
 */

import { permanentRedirect } from "next/navigation";

export default function LidCodeRedirect() {
  permanentRedirect("/");
}
