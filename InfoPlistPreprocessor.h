//
//  InfoPlistPreprocessor.h
//  MenuMeters
//
//  Created by Enrico Maria Crisostomo on 02/04/2017.
//
//

#ifndef InfoPlistPreprocessor_h
#define InfoPlistPreprocessor_h

// Version shown to a human: the release date, DD-MM-YYYY (IST). Bump this when
// cutting a build. Upstream's last numbered release was 2.1.6.1, which these
// builds are based on.
#define MM_VERSION  03-11-2026

// CFBundleVersion is a different thing: it has to sort. AppDelegate's
// killOlderInstances compares it with NSNumericSearch to decide whether an
// already-running copy is older than this one, and DD-MM-YYYY does not order
// correctly there -- comparing 30-10-2026 against 03-11-2026 compares 30 against
// 3 and concludes October is newer, so the stale instance would never be
// replaced and you would get two sets of meters in the menu bar.
//
// YYYY.MM.DD sorts correctly both numerically and as a plain string, so that is
// what goes in CFBundleVersion. Keep the two in step.
#define MM_BUILD    2026.11.03

#define MM_COPYRIGHT MenuMeters MM_VERSION, by many contributors

#endif /* InfoPlistPreprocessor_h */
