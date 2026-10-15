import { useEffect } from "react";
import type { MetaFunction } from "react-router";

export const meta: MetaFunction = () => [
  { title: "Soreno - Your voice, everywhere you work" },
  {
    name: "description",
    content:
      "Dictate into any app on macOS. Powered by on-device AI - fast, private, and always available. Free and open source.",
  },
];

const navLinks = [
  { href: "#features", label: "Features" },
  { href: "#how-it-works", label: "How it works" },
  { href: "#faq", label: "FAQ" },
];

const features = [
  {
    icon: <ShieldIcon />,
    title: "Completely private",
    desc: "Everything runs on your Mac. No audio is uploaded, recorded, or shared.",
  },
  {
    icon: <GridIcon />,
    title: "Works in every app",
    desc: "Claude Code, Codex, VS Code, Slack, Mail, Safari - wherever you type.",
  },
  {
    icon: <SparkleIcon />,
    title: "Smart formatting",
    desc: "On-device AI adds punctuation, numbers, capitalization, and structure.",
  },
  {
    icon: <GlobeIcon />,
    title: "More languages ahead",
    desc: "English is available today. Expanded on-device language support is on the roadmap.",
  },
  {
    icon: <SpeakerIcon />,
    title: "Read aloud",
    desc: "Highlight any text and Soreno reads it back for proofreading and accessibility.",
  },
  {
    icon: <InfinityIcon />,
    title: "No cloud costs",
    desc: "No API keys, no usage limits, and no recurring cloud charges.",
  },
];

const faqs = [
  {
    q: "Do I need an internet connection?",
    a: "Only for the initial download. After setup, Soreno works completely offline.",
  },
  {
    q: "What about my privacy?",
    a: "Soreno processes everything locally using on-device AI models. No audio recordings or transcripts are sent to external servers.",
  },
  {
    q: "Which apps does it work with?",
    a: "Any macOS app with a text field, including Claude Code, Codex, VS Code, Slack, Mail, Safari, Notes, and Pages.",
  },
  {
    q: "How accurate is the dictation?",
    a: "Soreno uses Apple Silicon optimized speech recognition plus local post-processing for punctuation and formatting.",
  },
  {
    q: "Is Soreno free?",
    a: "Yes. Soreno is free and open source under the MIT license.",
  },
  {
    q: "What languages are supported?",
    a: "Soreno is shipping with English today. Broader on-device language support is planned for a future release.",
  },
];

type SectionHeadingProps = {
  number: string;
  label: string;
  title: string;
  subtitle?: string;
};

export default function Home() {
  useEffect(() => {
    const nav = document.querySelector(".site-nav");

    const handleScroll = () => {
      nav?.classList.toggle("scrolled", window.scrollY > 28);
    };

    window.addEventListener("scroll", handleScroll, { passive: true });
    handleScroll();

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("visible");
          }
        });
      },
      { threshold: 0.1, rootMargin: "0px 0px -40px 0px" }
    );

    document.querySelectorAll(".reveal").forEach((el) => observer.observe(el));

    return () => {
      window.removeEventListener("scroll", handleScroll);
      observer.disconnect();
    };
  }, []);

  return (
    <>
      <QuoteDefs />
      <Nav />
      <main>
        <Hero />
        <HowItWorks />
        <Features />
        <Faq />
        <FinalCta />
      </main>
      <SiteFooter />
    </>
  );
}

function QuoteDefs() {
  return (
    <svg
      width="0"
      height="0"
      style={{ position: "absolute" }}
      aria-hidden="true"
      focusable="false"
    >
      <defs>
        <symbol id="quote" viewBox="0 0 100 140">
          <path
            d="M22 0 C6 0 -6 18 -6 42 C-6 66 12 82 34 82 C38 82 42 81 45 80 C41 105 22 123 2 130 L14 140 C56 128 82 92 82 50 C82 20 58 0 34 0 Z"
            transform="translate(0 0)"
          />
        </symbol>
      </defs>
    </svg>
  );
}

function Nav() {
  return (
    <nav className="site-nav">
      <div className="container site-nav__inner">
        <a href="/" className="brand" aria-label="Soreno home">
          <BrandMark className="brand__mark" />
          <span>Soreno</span>
        </a>

        <ul className="site-nav__links">
          {navLinks.map((link) => (
            <li key={link.href}>
              <a href={link.href}>{link.label}</a>
            </li>
          ))}
        </ul>

        <a href="#download" className="btn btn-primary site-nav__cta">
          Download
        </a>
      </div>
    </nav>
  );
}

function Hero() {
  return (
    <section className="hero" id="demo">
      <div className="hero__baselines" aria-hidden="true">
        {Array.from({ length: 8 }).map((_, index) => (
          <span key={index} style={{ top: `${20 + index * 9}%` }} />
        ))}
      </div>

      <div className="container hero__inner">
        <div>
          <p className="hero__eyebrow reveal">Local AI - Private - macOS</p>

          <h1 className="hero__title reveal">
            <QuoteGlyph className="hero__lead-quote" />
            Your voice,
            <br />
            <em>everywhere</em> you work.
          </h1>

          <p className="hero__subtitle reveal">
            Dictate into any app on your Mac. Powered by on-device AI - fast,
            private, and always available.
          </p>

          <div className="hero__actions reveal">
            <a href="#download" className="btn btn-primary">
              <AppleIcon />
              Download for macOS
            </a>
            <a href="#demo-panel" className="btn btn-ghost">
              Watch live demo <ArrowIcon />
            </a>
          </div>

          <p className="hero__small reveal">
            macOS 13+ - Apple Silicon - Free and open source
          </p>
        </div>

        <div id="demo-panel" className="hero-demo reveal">
          <div className="hero-demo__chrome">
            <div className="hero-demo__traffic" aria-hidden="true">
              <span />
              <span />
              <span />
            </div>
            <span className="mono-caption">Slack - #launch</span>
          </div>

          <p className="hero-demo__prompt">$ you, to the team</p>

          <p className="hero-demo__stream">
            <span className="captured">
              Let&apos;s ship the beta on Tuesday and share release notes on
              Wednesday morning.
            </span>
            <span className="hero-demo__caret" aria-hidden="true" />
          </p>

          <div className="hero-demo__bar">
            <div className="status">
              <span className="dot active" aria-hidden="true" />
              holding <span className="kbd">option</span>
              <span className="kbd">space</span>
            </div>
            <span className="mono-caption">12.4s - on-device</span>
          </div>
        </div>
      </div>
    </section>
  );
}

function SectionHeading({
  number,
  label,
  title,
  subtitle,
}: SectionHeadingProps) {
  return (
    <header className="section-head reveal">
      <span className="section-head__num">{number}</span>
      <QuoteGlyph className="section-head__quote" />
      <div className="section-head__content">
        <p className="section-head__label">{label}</p>
        <h2 className="section-head__title">{title}</h2>
        {subtitle ? <p className="section-head__subtitle">{subtitle}</p> : null}
      </div>
    </header>
  );
}

function HowItWorks() {
  return (
    <section id="how-it-works" className="section">
      <div className="container">
        <SectionHeading
          number="01"
          label="How it works"
          title="Three steps to hands-free"
          subtitle="No setup and no configuration. Hold a key and talk."
        />

        <div className="steps reveal-stagger">
          <article className="step reveal">
            <span className="step__number">1</span>
            <div className="step__icon">
              <KeyboardIcon />
            </div>
            <h3 className="step__title">Hold your key</h3>
            <p className="step__desc">
              Press and hold your shortcut key. Soreno starts listening
              instantly.
            </p>
            <div className="baseline-rule" aria-hidden="true" />
          </article>

          <article className="step reveal">
            <span className="step__number">2</span>
            <div className="step__icon">
              <WaveformIcon />
            </div>
            <h3 className="step__title">Speak naturally</h3>
            <p className="step__desc">
              Talk at your normal pace. No need to slow down or over-pronounce.
            </p>
            <div className="baseline-rule" aria-hidden="true" />
          </article>

          <article className="step reveal">
            <span className="step__number">3</span>
            <div className="step__icon">
              <CursorIcon />
            </div>
            <h3 className="step__title">Text appears</h3>
            <p className="step__desc">
              Clean formatted text is placed right where your cursor is, in any
              app.
            </p>
            <div className="baseline-rule" aria-hidden="true" />
          </article>
        </div>
      </div>
    </section>
  );
}

function Features() {
  return (
    <section id="features" className="section">
      <div className="container">
        <SectionHeading
          number="02"
          label="Features"
          title="Built around the quote mark"
          subtitle="One visual language across onboarding, capture, and output."
        />

        <div className="features-grid reveal-stagger">
          {features.map((feature, index) => (
            <article key={feature.title} className="feature-card reveal">
              <div className="feature-card__meta">
                <QuoteGlyph className="feature-card__quote" />
                <span className="mono-caption">
                  Feature {String(index + 1).padStart(2, "0")}
                </span>
              </div>
              <div className="feature-card__icon">{feature.icon}</div>
              <h3 className="feature-card__title">{feature.title}</h3>
              <p className="feature-card__desc">{feature.desc}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

function Faq() {
  return (
    <section id="faq" className="section">
      <div className="container container--narrow">
        <SectionHeading
          number="03"
          label="FAQ"
          title="Questions and answers"
        />

        <div className="faq-list reveal">
          {faqs.map((faq) => (
            <details key={faq.q} className="faq-item">
              <summary>{faq.q}</summary>
              <p>{faq.a}</p>
            </details>
          ))}
        </div>
      </div>
    </section>
  );
}

function FinalCta() {
  return (
    <section id="download" className="cta-section">
      <div className="container cta-section__inner reveal">
        <QuoteGlyph className="cta-section__quote" />
        <h2 className="cta-section__title">Ready to work hands-free?</h2>
        <p className="cta-section__subtitle">
          Download Soreno for free. No cloud account and no setup flow.
        </p>
        <a href="#" className="btn btn-primary btn-lg">
          <AppleIcon />
          Download for macOS
        </a>
        <p className="cta-section__note">
          macOS 13+ - Apple Silicon - Free and open source
        </p>
      </div>
    </section>
  );
}

function SiteFooter() {
  return (
    <footer className="footer">
      <div className="container footer__inner">
        <a href="/" className="brand footer__brand" aria-label="Soreno home">
          <BrandMark className="brand__mark" />
          <span>Soreno</span>
        </a>

        <ul className="footer__links">
          <li>
            <a href="/privacy">Privacy</a>
          </li>
          <li>
            <a href="/terms">Terms</a>
          </li>
          <li>
            <a href="mailto:adnone@soreno.app">Support</a>
          </li>
        </ul>

        <span className="mono-caption">
          &copy; {new Date().getFullYear()} Soreno
        </span>
      </div>
    </footer>
  );
}

function QuoteGlyph({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 100 140" aria-hidden="true">
      <use href="#quote" />
    </svg>
  );
}

function BrandMark({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 200 180" aria-hidden="true">
      <g fill="currentColor">
        <use href="#quote" x="0" y="0" />
        <use href="#quote" x="92" y="0" />
        <circle className="brand-dot" cx="18" cy="40" r="11" />
        <rect x="0" y="160" width="200" height="12" rx="6" />
      </g>
    </svg>
  );
}

function AppleIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
      <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
    </svg>
  );
}

function ArrowIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M5 12h14M12 5l7 7-7 7" />
    </svg>
  );
}

function KeyboardIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x="2" y="4" width="20" height="16" rx="2" />
      <path d="M6 8h.01M10 8h.01M14 8h.01M18 8h.01M8 12h.01M12 12h.01M16 12h.01M8 16h8" />
    </svg>
  );
}

function WaveformIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
    >
      <path d="M4 12h1M8 8v8M12 4v16M16 8v8M20 10v4" />
    </svg>
  );
}

function CursorIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M12 2v20M9 5h6M9 19h6" />
    </svg>
  );
}

function ShieldIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
      <path d="M9 12l2 2 4-4" />
    </svg>
  );
}

function GridIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x="3" y="3" width="7" height="7" rx="1.5" />
      <rect x="14" y="3" width="7" height="7" rx="1.5" />
      <rect x="3" y="14" width="7" height="7" rx="1.5" />
      <rect x="14" y="14" width="7" height="7" rx="1.5" />
    </svg>
  );
}

function SparkleIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M12 3l1.8 5.4L19 12l-5.2 3.6L12 21l-1.8-5.4L5 12l5.2-3.6z" />
    </svg>
  );
}

function GlobeIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <circle cx="12" cy="12" r="10" />
      <path d="M2 12h20" />
      <path d="M12 2a15.3 15.3 0 014 10 15.3 15.3 0 01-4 10 15.3 15.3 0 01-4-10 15.3 15.3 0 014-10z" />
    </svg>
  );
}

function SpeakerIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M11 5L6 9H2v6h4l5 4V5z" />
      <path d="M15.54 8.46a5 5 0 010 7.07" />
      <path d="M19.07 4.93a10 10 0 010 14.14" />
    </svg>
  );
}

function InfinityIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M12 12c-2-2.67-4-4-6-4a4 4 0 100 8c2 0 4-1.33 6-4zm0 0c2 2.67 4 4 6 4a4 4 0 000-8c-2 0-4 1.33-6 4z" />
    </svg>
  );
}

