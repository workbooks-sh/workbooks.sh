// Curated Lucide-icon map for agent :ICON: values.
//
// Extracted so AgentIcon (renderer) and AgentIconPicker (search +
// picker grid) share a single source of truth. New icons land here;
// nothing else needs to be touched.
//
// Each value is a Svelte component from @lucide/svelte. The key is
// the PascalCase name agent authors reference via lucide:<Name>.

import {
  Anvil,
  Bird,
  BookOpen,
  Bookmark,
  Bot,
  Brain,
  Cat,
  Code2,
  Compass,
  Cpu,
  Crown,
  Dog,
  Eye,
  Feather,
  FileText,
  Filter,
  Fish,
  Flag,
  Gauge,
  Ghost,
  Globe,
  GraduationCap,
  Hammer,
  Hash,
  Heart,
  Image,
  Key,
  Layers,
  Leaf,
  Lightbulb,
  Map,
  MessageCircle,
  Mic,
  Music,
  Newspaper,
  PenTool,
  Pin,
  Puzzle,
  Rabbit,
  Radar,
  Rocket,
  Search,
  Shapes,
  Shield,
  Sigma,
  Smile,
  Sparkle,
  Sparkles,
  Sprout,
  Squirrel,
  Star,
  Sun,
  Tag,
  Target,
  Telescope,
  Terminal,
  Trophy,
  Turtle,
  Umbrella,
  Video,
  Wallet,
  Wand2,
  Workflow,
  Wrench,
  Zap,
} from "@lucide/svelte";
import type { Component } from "svelte";

type IconComponent = Component<{ size?: number; strokeWidth?: number }>;

export const LUCIDE_MAP: Record<string, IconComponent> = {
  Anvil, Bird, BookOpen, Bookmark, Bot, Brain, Cat, Code2, Compass,
  Cpu, Crown, Dog, Eye, Feather, FileText, Filter, Fish, Flag, Gauge,
  Ghost, Globe, GraduationCap, Hammer, Hash, Heart, Image, Key,
  Layers, Leaf, Lightbulb, Map, MessageCircle, Mic, Music, Newspaper,
  PenTool, Pin, Puzzle, Rabbit, Radar, Rocket, Search, Shapes,
  Shield, Sigma, Smile, Sparkle, Sparkles, Sprout, Squirrel, Star,
  Sun, Tag, Target, Telescope, Terminal, Trophy, Turtle, Umbrella,
  Video, Wallet, Wand2, Workflow, Wrench, Zap,
};

export const LUCIDE_NAMES: string[] = Object.keys(LUCIDE_MAP).sort();
