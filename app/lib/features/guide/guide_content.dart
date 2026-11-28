import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/widgets/display.dart';
import 'guide_spotlight.dart';

/// One help topic in the guide.
class GuideTopic {
  const GuideTopic({
    required this.id,
    required this.title,
    required this.icon,
    required this.tint,
    required this.summary,
    required this.steps,
    this.route,
    this.screens = const [],
    this.keywords = '',
  });

  final String id, title, summary;
  final IconData icon;
  final Color tint;
  final List<GuideStep> steps;

  /// Where "Take me there" goes. `add` opens the Add-a-purchase sheet.
  final String? route;

  /// Route patterns (regular expressions on the path) where this topic is
  /// relevant, for "On this screen".
  final List<String> screens;
  final String keywords;

  bool matches(String path) => screens.any((p) => RegExp(p).hasMatch(path));

  bool search(String q) {
    final s = q.toLowerCase().trim();
    if (s.isEmpty) return true;
    return '$title $summary $keywords ${steps.map((s) => s.text).join(' ')}'.toLowerCase().contains(s);
  }
}

const guideTopics = <GuideTopic>[
  GuideTopic(
    id: 'start',
    title: 'Getting started',
    icon: PhosphorIconsRegular.flag,
    tint: WTint.violet,
    summary: 'Keep your receipts and warranties in one place, and get a nudge before anything runs out.',
    steps: [
      GuideStep('Bought something? Tap this + button to add it.', target: 'nav.add'),
      GuideStep('Have a quick look at the dates I found, then save. That’s it!'),
      GuideStep('Home is your to-do list. I’ll remind you before each deadline.', target: 'nav.home'),
    ],
    route: '/home',
    screens: [r'^/home$'],
    keywords: 'begin intro how to use first start',
  ),
  GuideTopic(
    id: 'home',
    title: 'Home',
    icon: PhosphorIconsRegular.house,
    tint: WTint.violet,
    summary: 'Your to-do list: returns closing soon, things to register and warranties ending.',
    steps: [
      GuideStep('The most urgent thing is always at the top. Tap it to sort it out.', target: 'home.attention'),
      GuideStep('Your latest purchases live down here.', target: 'home.recent'),
    ],
    route: '/home',
    screens: [r'^/home$'],
    keywords: 'action center dashboard attention urgent today to do',
  ),
  GuideTopic(
    id: 'add',
    title: 'Add something you bought',
    icon: PhosphorIconsRegular.plusCircle,
    tint: WTint.green,
    summary: 'Snap the receipt, upload a photo or PDF, or just type it in.',
    steps: [
      GuideStep('Snap your receipt and I’ll fill in the shop, date and price for you.', target: 'add.scan'),
      GuideStep('Already have a photo or an email receipt? Upload it here.', target: 'add.upload'),
      GuideStep('No receipt? No problem. Type it in yourself. It’s always free.', target: 'add.manual'),
    ],
    route: 'add',
    screens: [r'^/capture/(manual|ai-consent|ai-limit)'],
    keywords: 'new item scan receipt upload photo pdf manual label camera add',
  ),
  GuideTopic(
    id: 'review',
    title: 'Check a scanned receipt',
    icon: PhosphorIconsRegular.listChecks,
    tint: WTint.green,
    summary: 'After a scan, check what I read. Nothing is saved until you say so.',
    steps: [
      GuideStep('Compare each box with your receipt. If I wasn’t sure, I left it empty.'),
      GuideStep('One receipt with lots of things? Keep just the ones you care about.'),
      GuideStep('Tap confirm to save. I keep the receipt photo safe in your Vault.'),
    ],
    screens: [r'^/capture/(review|scan|product|coverage|failed|upload-issue)'],
    keywords: 'review scan result fields confirm ai read check',
  ),
  GuideTopic(
    id: 'items',
    title: 'Your items',
    icon: PhosphorIconsRegular.package,
    tint: WTint.violet,
    summary: 'Everything you own in one list, with how long each warranty has left.',
    steps: [
      GuideStep('Looking for something? Type its name, brand or shop here.', target: 'items.search'),
      GuideStep('Tap a filter to see only returns, registrations or what’s still covered.', target: 'items.filters'),
      GuideStep('Change the order here, like newest first or most urgent.', target: 'items.sort'),
    ],
    route: '/items',
    screens: [r'^/items$'],
    keywords: 'list search filter sort covered expired',
  ),
  GuideTopic(
    id: 'item',
    title: 'An item’s page',
    icon: PhosphorIconsRegular.squaresFour,
    tint: WTint.violet,
    summary: 'Everything about one thing you own: warranty, returns, documents and claims.',
    steps: [
      GuideStep('Here’s the warranty and when it ends. Tap it to check or fix the dates.', target: 'item.coverage'),
      GuideStep('Add a return window or a registration reminder here.', target: 'item.registration'),
      GuideStep('Something broke? Start a claim here and I’ll help you get it sorted.', target: 'item.claims'),
    ],
    screens: [r'^/items/[^/]+$', r'^/items/[^/]+/edit$'],
    keywords: 'detail timeline edit serial model price page',
  ),
  GuideTopic(
    id: 'coverage',
    title: 'Warranties',
    icon: PhosphorIconsRegular.shieldCheck,
    tint: WTint.blue,
    summary: 'Tell me what protects an item and for how long, and I’ll warn you before it ends.',
    steps: [
      GuideStep('Pick who gives the warranty, like the maker, the shop or an extended plan.'),
      GuideStep('Set how many months it lasts, or the exact end date.'),
      GuideStep('Not sure of the date? Choose “Estimate” and I’ll mark it until you confirm.'),
    ],
    screens: [r'^/items/[^/]+/coverage'],
    keywords: 'warranty guarantee protection plan months end date estimated confirm coverage',
  ),
  GuideTopic(
    id: 'returns',
    title: 'Returns',
    icon: PhosphorIconsRegular.arrowUUpLeft,
    tint: WTint.green,
    summary: 'Never miss the last day to send something back.',
    steps: [
      GuideStep('Choose “30 days” style, or pick the exact last day.'),
      GuideStep('I’ll remind you before time runs out.'),
      GuideStep('Sending it back? Keep the tracking number and refund here.'),
    ],
    screens: [r'^/items/[^/]+/return'],
    keywords: 'return refund deadline window rma send back',
  ),
  GuideTopic(
    id: 'registration',
    title: 'Registering a product',
    icon: PhosphorIconsRegular.clipboardText,
    tint: WTint.amber,
    summary: 'Some makers give you extra perks if you register. I’ll keep the link and remind you.',
    steps: [
      GuideStep('Tell me if registering is optional, gives a bonus or is required.'),
      GuideStep('Paste the registration link and pick a “remind me by” date.'),
      GuideStep('Done it? Tap “I already registered” and I’ll stop reminding you.'),
    ],
    screens: [r'^/items/[^/]+/registration'],
    keywords: 'register manufacturer benefit confirmation',
  ),
  GuideTopic(
    id: 'vault',
    title: 'Your Vault',
    icon: PhosphorIconsRegular.vault,
    tint: WTint.blue,
    summary: 'A safe, private place for every receipt, warranty card and manual.',
    steps: [
      GuideStep('Tap Upload to add any document.', target: 'vault.upload'),
      GuideStep('Use these to show only receipts, warranties, manuals or photos.', target: 'vault.filters'),
    ],
    route: '/vault',
    screens: [r'^/vault'],
    keywords: 'documents files receipts manuals photos storage upload proof vault',
  ),
  GuideTopic(
    id: 'claims',
    title: 'Claims',
    icon: PhosphorIconsRegular.lifebuoy,
    tint: WTint.coral,
    summary: 'Something broke? I gather the proof so asking for a repair or refund is easy.',
    steps: [
      GuideStep('Here’s how your claims are going and when to follow up.', target: 'claims.summary'),
      GuideStep('To start one, open the item and tap Start under “Claims & returns”.'),
      GuideStep('I put the receipt, warranty and dates into one pack. You send it, then tell me how it went.'),
    ],
    route: '/claims',
    screens: [r'^/claims'],
    keywords: 'claim repair replacement broken fault pack letter follow up',
  ),
  GuideTopic(
    id: 'outcomes',
    title: 'Outcomes',
    icon: PhosphorIconsRegular.trophy,
    tint: WTint.orchid,
    summary: 'Write down how things ended: refunded, repaired, replaced or turned down.',
    steps: [
      GuideStep('When a claim or return is finished, tell me what happened.'),
      GuideStep('Got money back? Add the amount. It shows up in “Your year”.'),
    ],
    route: '/outcomes',
    screens: [r'^/outcomes'],
    keywords: 'result refund repaired replaced denied outcome',
  ),
  GuideTopic(
    id: 'reminders',
    title: 'Reminders',
    icon: PhosphorIconsRegular.bell,
    tint: WTint.amber,
    summary: 'Choose when I nudge you about returns, warranties and more.',
    steps: [
      GuideStep('Pick the time of day you’d like my reminders.', target: 'reminders.time'),
      GuideStep('For each kind, choose how early I should tell you, like a week or a day before.', target: 'reminders.kinds'),
    ],
    route: '/settings/reminders',
    screens: [r'^/settings/reminders'],
    keywords: 'notification alert push time day before reminder',
  ),
  GuideTopic(
    id: 'plan',
    title: 'Free and Pro',
    icon: PhosphorIconsRegular.crown,
    tint: WTint.amber,
    summary: 'Free covers the basics. Pro gives you more room, more AI help and sharing.',
    steps: [
      GuideStep('See how much of your plan you’ve used here.', target: 'plan.usage'),
      GuideStep('Curious about Pro? Tap here to compare. If Pro ever ends, you keep everything.', target: 'plan.pro'),
    ],
    route: '/settings/plan',
    screens: [r'^/settings/(plan|paywall)'],
    keywords: 'pro subscription price upgrade limit usage storage ai reads billing plan',
  ),
  GuideTopic(
    id: 'household',
    title: 'Sharing with family',
    icon: PhosphorIconsRegular.usersThree,
    tint: WTint.green,
    summary: 'Share your things with family. Everyone gets their own reminders. (A Pro feature.)',
    steps: [
      GuideStep('Create a household, then invite your family.'),
      GuideStep('Share an item from its page. Its receipt and warranty come too.'),
    ],
    route: '/household',
    screens: [r'^/household'],
    keywords: 'family share members invite household',
  ),
  GuideTopic(
    id: 'digest',
    title: 'Your month and your year',
    icon: PhosphorIconsRegular.calendarCheck,
    tint: WTint.violet,
    summary: 'A monthly look at what’s due, and a summary of your year.',
    steps: [
      GuideStep('Monthly digest lists this month’s deadlines in date order.'),
      GuideStep('“Your year” shows how much you kept track of, and any refunds.'),
    ],
    route: '/settings/digest',
    screens: [r'^/settings/(digest|annual)'],
    keywords: 'month summary year review stats digest',
  ),
  GuideTopic(
    id: 'privacy',
    title: 'Privacy',
    icon: PhosphorIconsRegular.lockSimple,
    tint: WTint.blue,
    summary: 'Your files are private to you. You decide if AI reads your receipts.',
    steps: [
      GuideStep('Switch AI reading on or off. Off means you type things in yourself.'),
      GuideStep('You can download or delete your data whenever you like.'),
    ],
    route: '/settings/privacy',
    screens: [r'^/settings/privacy'],
    keywords: 'privacy ai consent analytics data security',
  ),
  GuideTopic(
    id: 'export',
    title: 'Download your data',
    icon: PhosphorIconsRegular.export,
    tint: WTint.blue,
    summary: 'Take a copy of everything, any time, on any plan.',
    steps: [
      GuideStep('Tap “Prepare export” and give me a moment.'),
      GuideStep('Then download your items, warranties, claims and documents.'),
    ],
    route: '/settings/export',
    screens: [r'^/settings/export'],
    keywords: 'download backup json copy export',
  ),
  GuideTopic(
    id: 'signin',
    title: 'Signing in with Google',
    icon: PhosphorIconsRegular.key,
    tint: WTint.violet,
    summary: 'Use your email, Google, or both for the same account.',
    steps: [
      GuideStep('Here’s how you can sign in right now.', target: 'signin.list'),
      GuideStep('Tap Add next to Google and pick the Google account with the same email. Then Google signs you straight in.'),
    ],
    route: '/settings/sign-in-methods',
    screens: [r'^/settings/sign-in-methods'],
    keywords: 'google login password account link sign in',
  ),
  GuideTopic(
    id: 'settings',
    title: 'Settings',
    icon: PhosphorIconsRegular.gear,
    tint: WTint.violet,
    summary: 'Your plan, reminders, privacy, look and account.',
    steps: [
      GuideStep('Pick light, dark, or match your phone.', target: 'settings.appearance'),
      GuideStep('Need a hand? “Help & support” sends us a message.'),
    ],
    route: '/settings',
    screens: [r'^/settings$', r'^/settings/(region|support|switch-account|delete-account|email-forwarding)'],
    keywords: 'appearance dark light theme region currency support account settings',
  ),
];

/// The first-login tour of the main screens.
const guideIntroTour = <GuideStep>[
  GuideStep('This is Home, your to-do list. The most urgent thing is always on top.', target: 'nav.home', title: 'Home'),
  GuideStep('Bought something? Tap + to add it. Snapping the receipt is the quickest way.', target: 'nav.add', title: 'Add a purchase'),
  GuideStep('All your things live here, with how long each warranty has left.', target: 'nav.items', title: 'Items'),
  GuideStep('Every receipt and warranty card, kept safe and private.', target: 'nav.vault', title: 'Vault'),
  GuideStep('Reminders, your plan and privacy are in Settings.', target: 'nav.settings', title: 'Settings'),
  GuideStep('And that’s me! Tap me on any screen and I’ll show you how things work.', target: 'guide.button', title: 'Need help?'),
];
