---
layout: article
title: Astrophotography Planner Design
date: 2026-05-30
series: "Design"
series_order: 3
categories: astrophotography pipelines image-processing design
published: false
---

# Inputs
* location for the observatory
* horizon profile (optional) 
* list of objects with positions and maybe type of photography (LRGB/SHO)
* minimal altitude above the horizon
* time-period

From these inputs (horizon profile, location and minimal altitude) we can determine for each declination value, which hour-angle ranges are visible. So for each observatory we can create a declination-hour-angle profile. It would then be easy to determine, when each object would be visible in the time-period, by using its declination to determine valid hour angles, and then using the right ascension together with the hour angle ranges to determine the sidereal time ranges when the object is visible. 

# Store
We will probably want to store observatory location and horizon profile, together with a name for the location. The user should be able to add/edit/delete observatories. Maybe also store the hour-angle per declination ranges for the observatory (per 5° or maybe 1°?).
Should we use the archive SQLite store for this also?

# Output 
The app should be able to evaluate for each object how good the conditions are for each observation night. This should be based on the number of hours the object is visible, the altitude above the horizon, the elongation from the Sun, the elongation from the Moon and the phase of the Moon, whether the Sun and Moon are above the horizon. Also take into acount if we are doing LRGB or single shot color camera observations or narrow band observations. Narrow band is more forgiving for moon-light and twilight. But there is a difference between OIII and Hɑ, for instance.

