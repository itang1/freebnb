// Import the functions you need from the SDKs you need
import { initializeApp } from "firebase/app";
import { getAnalytics } from "firebase/analytics";
// TODO: Add SDKs for Firebase products that you want to use
// https://firebase.google.com/docs/web/setup#available-libraries

// Your web app's Firebase configuration
// For Firebase JS SDK v7.20.0 and later, measurementId is optional
const firebaseConfig = {
  apiKey: "AIzaSyANXqRhcDCpbiM1K52SgayjYA8J1FAIyrs",
  authDomain: "freebnb-6814a.firebaseapp.com",
  projectId: "freebnb-6814a",
  storageBucket: "freebnb-6814a.firebasestorage.app",
  messagingSenderId: "886039659486",
  appId: "1:886039659486:web:58883564bb8b66d6d4534f",
  measurementId: "G-DHTL72X3PM"
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);
const analytics = getAnalytics(app);