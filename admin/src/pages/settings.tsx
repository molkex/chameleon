import { useState, useEffect } from "react";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/lib/api";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { toast } from "sonner";
import { Save } from "lucide-react";

interface BrandingSettings {
  profile_title: string;
  brand_name: string;
  support_url: string;
  support_channel: string;
  web_page_url: string;
  update_interval: string;
  brand_emoji: string;
  support_emoji: string;
  channel_emoji: string;
}

export default function SettingsPage() {
  const queryClient = useQueryClient();
  const { data } = useQuery({
    queryKey: ["branding"],
    queryFn: () => api.get<{ settings: BrandingSettings }>("/admin/settings/branding").then((r) => r.settings),
  });

  const [form, setForm] = useState<BrandingSettings>({
    profile_title: "", brand_name: "", support_url: "", support_channel: "",
    web_page_url: "", update_interval: "12", brand_emoji: "", support_emoji: "", channel_emoji: "",
  });

  useEffect(() => {
    if (data) setForm(data);
  }, [data]);

  const saveMutation = useMutation({
    mutationFn: () => api.patch("/admin/settings/branding", form),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["branding"] });
      toast.success("Settings saved");
    },
    onError: (e) => toast.error(`Save failed: ${e.message}`),
  });

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-bold">Settings</h1>

      <Card>
        <CardHeader><CardTitle>Branding</CardTitle></CardHeader>
        <CardContent className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label>Brand Name</Label>
              <Input value={form.brand_name} onChange={(e) => setForm({ ...form, brand_name: e.target.value })}
                placeholder="Chameleon VPN" />
            </div>
            <div className="space-y-2">
              <Label>Profile Title</Label>
              <Input value={form.profile_title} onChange={(e) => setForm({ ...form, profile_title: e.target.value })}
                placeholder="Chameleon VPN" />
            </div>
            <div className="space-y-2">
              <Label>Support URL</Label>
              <Input value={form.support_url} onChange={(e) => setForm({ ...form, support_url: e.target.value })}
                placeholder="https://t.me/support" />
            </div>
            <div className="space-y-2">
              <Label>Support Channel</Label>
              <Input value={form.support_channel} onChange={(e) => setForm({ ...form, support_channel: e.target.value })}
                placeholder="https://t.me/channel" />
            </div>
            <div className="space-y-2">
              <Label>Website URL</Label>
              <Input value={form.web_page_url} onChange={(e) => setForm({ ...form, web_page_url: e.target.value })}
                placeholder="https://example.com" />
            </div>
            <div className="space-y-2">
              <Label>Update Interval (hours)</Label>
              <Input value={form.update_interval} onChange={(e) => setForm({ ...form, update_interval: e.target.value })}
                placeholder="12" />
            </div>
          </div>
          <Button onClick={() => saveMutation.mutate()} disabled={saveMutation.isPending}>
            <Save className="mr-2 h-4 w-4" />
            Save Changes
          </Button>
        </CardContent>
      </Card>
    </div>
  );
}
