import { ArchiveViewer } from "@/components/ArchiveViewer";
import { BackgroundBoxesDemo } from "@/components/BackgroundBoxesDemo";

export default function Home() {
  return (
    <main className="flex min-h-screen flex-col bg-slate-950 text-white">
      <BackgroundBoxesDemo />
      <div className="relative flex-1">
        <ArchiveViewer />
      </div>
    </main>
  );
}
